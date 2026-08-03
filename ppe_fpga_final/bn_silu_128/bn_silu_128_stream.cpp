#include "ap_int.h"
#include "hls_math.h"
#include "hls_stream.h"

#define CH   128     // 64 -> 128
#define H    40
#define W    40
#define N_PIX (H * W)

typedef struct { ap_int<32> ch[CH]; } in_pix_t;    // 4096 bit
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;   // 1024 bit

void bn_silu_128_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    float bn_scale[CH],
    float bn_shift[CH],
    float input_scale,
    float weight_scale,
    float output_scale
) {
#pragma HLS INTERFACE axis      port=in_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=bn_scale
#pragma HLS INTERFACE bram      port=bn_shift
#pragma HLS INTERFACE s_axilite port=input_scale
#pragma HLS INTERFACE s_axilite port=weight_scale
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // 더블 버퍼: bn_silu_64에서 검증된 패턴 그대로.
    // 픽셀 홀짝으로 번갈아 써서 c==0 쓰기와 이전 픽셀의 마지막
    // 읽기가 겹쳐도 충돌하지 않게 합니다 (II=1 유지의 핵심).
    ap_int<32> ibuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=ibuf complete dim=0

    ap_int<8>  obuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    float in_w_scale = input_scale * weight_scale;
    float inv_out    = 1.0f / output_scale;

    // t = pixel * CH + c
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
        float bn_out    = x_float * bn_scale[c] + bn_shift[c];
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