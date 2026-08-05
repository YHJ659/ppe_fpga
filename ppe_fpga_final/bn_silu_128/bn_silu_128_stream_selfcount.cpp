#include "ap_int.h"
#include "hls_math.h"
#include "hls_stream.h"

#define CH      128
#define H       40
#define W       40
#define N_PIX   (H * W)
#define N_SET   2     // cv1측(conv1x1_cv1 뒤), cv2측(conv1x1_cv2 뒤) — 프레임당 2회 재사용

typedef struct { ap_int<32> ch[CH]; } in_pix_t;    // 4096 bit
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;   // 1024 bit

// ============================================================
//  bn_silu_64와 완전히 동일한 패턴, CH/N_SET만 다름.
//  bn128_router가 두 번(1.cv1_out→bn_in, 3.cv2_out→bn_in) 이
//  IP를 부르는데, 라우터는 데이터 순서만 맞춰줄 뿐 call_counter
//  자체는 이 IP가 스스로 셉니다.
// ============================================================
void bn_silu_128_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    float bn_scale[N_SET][CH],
    float bn_shift[N_SET][CH],
    float input_scale[N_SET],
    float weight_scale[N_SET],
    float output_scale[N_SET]
) {
#pragma HLS INTERFACE axis      port=in_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=bn_scale
#pragma HLS INTERFACE bram      port=bn_shift
#pragma HLS INTERFACE bram      port=input_scale
#pragma HLS INTERFACE bram      port=weight_scale
#pragma HLS INTERFACE bram      port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    static int call_counter = 0;
    int my_set = call_counter % N_SET;
    call_counter++;

    float in_w_scale = input_scale[my_set] * weight_scale[my_set];
    float inv_out    = 1.0f / output_scale[my_set];

    // 더블 버퍼: 기존 확정본과 완전히 동일 — 변경 없음
    ap_int<32> ibuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=ibuf complete dim=0

    ap_int<8>  obuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1

        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            in_pix_t px = in_s.read();
            UNPACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                ibuf[par][i] = px.ch[i];
            }
        }

        float x_float   = ibuf[par][c].to_float() * in_w_scale;
        float mult_tmp  = x_float * bn_scale[my_set][c];
        float bn_out;
#pragma HLS BIND_OP variable=bn_out op=fadd impl=fulldsp
        bn_out = mult_tmp + bn_shift[my_set][c];
        float sigmoid_x = 1.0f / (1.0f + hls::exp(-bn_out));
        float silu_out  = bn_out * sigmoid_x;

        float q = silu_out * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][c] = y_int;

        if (c == CH - 1) {
            out_pix_t oy;
            PACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
        }
    }
}