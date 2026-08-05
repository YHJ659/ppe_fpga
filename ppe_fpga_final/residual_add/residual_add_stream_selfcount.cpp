#include "ap_int.h"
#include "hls_stream.h"

#define CH      64
#define H       40
#define W       40
#define N_PIX   (H * W)
#define N_SET   2     // Bottleneck0, Bottleneck1 — 프레임당 2회 재사용

typedef struct { ap_int<8> ch[CH]; } pix_t;   // 512 bit

// ============================================================
//  conv3x3/bn_silu_64와 같은 문제, 같은 해법. 배열이 작아
//  (3개 스칼라 x 2벌 = 24바이트) URAM은 아예 필요 없습니다.
//  기존 s_axilite 스칼라 3개를 [N_SET] 배열로 바꾸고,
//  call_counter가 스스로 Bottleneck0/1을 구분합니다.
// ============================================================
void residual_add_stream(
    hls::stream<pix_t> &x_s,    // shortcut 경로
    hls::stream<pix_t> &fx_s,   // conv 경로 F(x)
    hls::stream<pix_t> &out_s,
    float x_scale[N_SET],
    float fx_scale[N_SET],
    float output_scale[N_SET]
) {
#pragma HLS INTERFACE axis      port=x_s
#pragma HLS INTERFACE axis      port=fx_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=x_scale
#pragma HLS INTERFACE bram      port=fx_scale
#pragma HLS INTERFACE bram      port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=x_s
#pragma HLS AGGREGATE compact=bit variable=fx_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    static int call_counter = 0;
    int my_set = call_counter % N_SET;
    call_counter++;

    float x_s_val  = x_scale[my_set];
    float fx_s_val = fx_scale[my_set];
    float inv_out  = 1.0f / output_scale[my_set];

    // 더블 버퍼: 기존 확정본과 완전히 동일 — 변경 없음
    ap_int<8> xbuf [2][CH];
    ap_int<8> fxbuf[2][CH];
    ap_int<8> obuf [2][CH];
#pragma HLS ARRAY_PARTITION variable=xbuf  complete dim=0
#pragma HLS ARRAY_PARTITION variable=fxbuf complete dim=0
#pragma HLS ARRAY_PARTITION variable=obuf  complete dim=0

    MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1

        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            pix_t xp  = x_s.read();
            pix_t fxp = fx_s.read();
            UNPACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                xbuf[par][i]  = xp.ch[i];
                fxbuf[par][i] = fxp.ch[i];
            }
        }

        float x_float  = xbuf[par][c].to_float()  * x_s_val;
        float fx_float = fxbuf[par][c].to_float() * fx_s_val;
        float sum = x_float + fx_float;

        float q = sum * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][c] = y_int;

        if (c == CH - 1) {
            pix_t oy;
            PACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
        }
    }
}