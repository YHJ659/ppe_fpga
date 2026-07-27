#include "ap_int.h"

#define CH_PER_BRANCH  64
#define OUT_CH         256
#define H              40
#define W              40

void concat_channel(
    ap_int<8> y0[CH_PER_BRANCH][H][W],
    ap_int<8> y1[CH_PER_BRANCH][H][W],
    ap_int<8> y2[CH_PER_BRANCH][H][W],
    ap_int<8> y3[CH_PER_BRANCH][H][W],
    float     scale0,
    float     scale1,
    float     scale2,
    float     scale3,
    float     output_scale,
    ap_int<8> output[OUT_CH][H][W]
) {
#pragma HLS INTERFACE bram port=y0
#pragma HLS INTERFACE bram port=y1
#pragma HLS INTERFACE bram port=y2
#pragma HLS INTERFACE bram port=y3
#pragma HLS INTERFACE bram port=output
#pragma HLS INTERFACE s_axilite port=scale0
#pragma HLS INTERFACE s_axilite port=scale1
#pragma HLS INTERFACE s_axilite port=scale2
#pragma HLS INTERFACE s_axilite port=scale3
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return

#pragma HLS ARRAY_PARTITION variable=output type=block factor=4 dim=1

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
#pragma HLS PIPELINE II=1
            for (int c = 0; c < CH_PER_BRANCH; c++) {
                float v0 = y0[c][h][w].to_float() * scale0;
                float v1 = y1[c][h][w].to_float() * scale1;
                float v2 = y2[c][h][w].to_float() * scale2;
                float v3 = y3[c][h][w].to_float() * scale3;

                int q0 = (int)(v0 / output_scale + (v0 >= 0 ? 0.5f : -0.5f));
                int q1 = (int)(v1 / output_scale + (v1 >= 0 ? 0.5f : -0.5f));
                int q2 = (int)(v2 / output_scale + (v2 >= 0 ? 0.5f : -0.5f));
                int q3 = (int)(v3 / output_scale + (v3 >= 0 ? 0.5f : -0.5f));

                output[c][h][w]                  = (q0 > 127) ? 127 : (q0 < -128 ? -128 : q0);
                output[c + CH_PER_BRANCH][h][w]   = (q1 > 127) ? 127 : (q1 < -128 ? -128 : q1);
                output[c + 2*CH_PER_BRANCH][h][w] = (q2 > 127) ? 127 : (q2 < -128 ? -128 : q2);
                output[c + 3*CH_PER_BRANCH][h][w] = (q3 > 127) ? 127 : (q3 < -128 ? -128 : q3);
            }
        }
    }
}
