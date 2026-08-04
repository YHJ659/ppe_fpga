#include "ap_int.h"
#include "hls_stream.h"

#define CH        64      // branch당 채널 수
#define OUT_CH    256     // 4 * CH
#define H         40
#define W         40
#define N_PIX     (H * W)

typedef struct { ap_int<8> ch[CH];     } pix_t;      // 512 bit
typedef struct { ap_int<8> ch[OUT_CH]; } out_pix_t;  // 2048 bit

static void buffer01(
    hls::stream<pix_t> &y0_s,
    hls::stream<pix_t> &y1_s,
    ap_int<8> y0_buf[CH][H][W],
    ap_int<8> y1_buf[CH][H][W]
) {
    ap_int<8> p0[2][CH], p1[2][CH];
#pragma HLS ARRAY_PARTITION variable=p0 complete dim=0
#pragma HLS ARRAY_PARTITION variable=p1 complete dim=0

    int h = 0, w = 0;
    BUF01_MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1
        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            pix_t a = y0_s.read();
            pix_t b = y1_s.read();
            UNPACK01: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                p0[par][i] = a.ch[i];
                p1[par][i] = b.ch[i];
            }
        }

        y0_buf[c][h][w] = p0[par][c];
        y1_buf[c][h][w] = p1[par][c];

        if (c == CH - 1) { w++; if (w == W) { w = 0; h++; } }
    }
}

static void buffer2(
    hls::stream<pix_t> &y2_s,
    ap_int<8> y2_buf[CH][H][W]
) {
    ap_int<8> p2[2][CH];
#pragma HLS ARRAY_PARTITION variable=p2 complete dim=0

    int h = 0, w = 0;
    BUF2_MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1
        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            pix_t b = y2_s.read();
            UNPACK2: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                p2[par][i] = b.ch[i];
            }
        }

        y2_buf[c][h][w] = p2[par][c];

        if (c == CH - 1) { w++; if (w == W) { w = 0; h++; } }
    }
}

static void combine(
    hls::stream<pix_t> &y3_s,
    ap_int<8> y0_buf[CH][H][W],
    ap_int<8> y1_buf[CH][H][W],
    ap_int<8> y2_buf[CH][H][W],
    float scale0, float scale1, float scale2, float scale3,
    float output_scale,
    hls::stream<out_pix_t> &out_s
) {
    ap_int<8>  p3[2][CH];
#pragma HLS ARRAY_PARTITION variable=p3 complete dim=0
    ap_int<8>  obuf[2][OUT_CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    float inv_out = 1.0f / output_scale;
    int h = 0, w = 0;

    COMBINE_MAIN: for (int t = 0; t < N_PIX * OUT_CH; t++) {
#pragma HLS PIPELINE II=1
        int oc  = t % OUT_CH;
        int par = (t / OUT_CH) & 1;
        int branch = oc / CH;
        int lc     = oc % CH;

        if (oc == 3 * CH) {
            pix_t d = y3_s.read();
            UNPACK3: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                p3[par][i] = d.ch[i];
            }
        }

        ap_int<8> raw;
        float scale;
        if      (branch == 0) { raw = y0_buf[lc][h][w]; scale = scale0; }
        else if (branch == 1) { raw = y1_buf[lc][h][w]; scale = scale1; }
        else if (branch == 2) { raw = y2_buf[lc][h][w]; scale = scale2; }
        else                  { raw = p3[par][lc];       scale = scale3; }

        float v = raw.to_float() * scale;
        float q = v * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][oc] = y_int;

        if (oc == OUT_CH - 1) {
            out_pix_t oy;
            PACKC: for (int i = 0; i < OUT_CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
            w++; if (w == W) { w = 0; h++; }
        }
    }
}

void concat_channel_stream(
    hls::stream<pix_t>  &y0_s,
    hls::stream<pix_t>  &y1_s,
    hls::stream<pix_t>  &y2_s,
    hls::stream<pix_t>  &y3_s,
    float scale0, float scale1, float scale2, float scale3, float output_scale,
    hls::stream<out_pix_t> &out_s
) {
#pragma HLS INTERFACE axis      port=y0_s
#pragma HLS INTERFACE axis      port=y1_s
#pragma HLS INTERFACE axis      port=y2_s
#pragma HLS INTERFACE axis      port=y3_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE s_axilite port=scale0
#pragma HLS INTERFACE s_axilite port=scale1
#pragma HLS INTERFACE s_axilite port=scale2
#pragma HLS INTERFACE s_axilite port=scale3
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=y0_s
#pragma HLS AGGREGATE compact=bit variable=y1_s
#pragma HLS AGGREGATE compact=bit variable=y2_s
#pragma HLS AGGREGATE compact=bit variable=y3_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // ★ URAM은 블록 하나의 깊이가 4,096으로 고정입니다. 파티션 없이
    // 8bit 폭으로 102,400개를 담으려니 블록을 25개씩 이어붙여야 했고
    // (버퍼 3개 x 25 = 75), 이게 URAM 75개의 정확한 원인이었습니다.
    // BRAM 때 썼던 ARRAY_RESHAPE로 8개씩 묶어 64bit 워드로 만들면
    // (URAM 폭 72bit 안에 여유 있게 들어감) 깊이가 12,800으로 줄어
    // 블록 수도 버퍼당 약 4개(3개 x 4 = 12개)로 크게 줄어들 것으로
    // 예상합니다.
    ap_int<8> y0_buf[CH][H][W];
    ap_int<8> y1_buf[CH][H][W];
    ap_int<8> y2_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=y0_buf cyclic factor=8 dim=3
#pragma HLS ARRAY_RESHAPE variable=y1_buf cyclic factor=8 dim=3
#pragma HLS ARRAY_RESHAPE variable=y2_buf cyclic factor=8 dim=3
#pragma HLS BIND_STORAGE variable=y0_buf type=ram_1p impl=uram
#pragma HLS BIND_STORAGE variable=y1_buf type=ram_1p impl=uram
#pragma HLS BIND_STORAGE variable=y2_buf type=ram_1p impl=uram

    buffer01(y0_s, y1_s, y0_buf, y1_buf);
    buffer2(y2_s, y2_buf);
    combine(y3_s, y0_buf, y1_buf, y2_buf, scale0, scale1, scale2, scale3, output_scale, out_s);
}