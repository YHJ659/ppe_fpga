#include "ap_int.h"
#include "hls_math.h"

#define CH   64
#define H    40
#define W    40

void bn_silu(
    ap_int<32> conv_out[CH][H][W],
    float      bn_scale[CH],
    float      bn_shift[CH],
    float      input_scale,     // #define 대신 런타임 인자로 변경
    float      weight_scale,    // 마찬가지
    float      output_scale,    // 마찬가지
    ap_int<8>  output[CH][H][W]
) {
#pragma HLS INTERFACE bram port=conv_out
#pragma HLS INTERFACE bram port=bn_scale
#pragma HLS INTERFACE bram port=bn_shift
#pragma HLS INTERFACE bram port=output
#pragma HLS INTERFACE s_axilite port=input_scale
#pragma HLS INTERFACE s_axilite port=weight_scale
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return

    for (int c = 0; c < CH; c++) {
        for (int h = 0; h < H; h++) {
            for (int w = 0; w < W; w++) {
#pragma HLS PIPELINE II=1
                float x_float = conv_out[c][h][w].to_float() * input_scale * weight_scale;
                float bn_out = x_float * bn_scale[c] + bn_shift[c];
                float sigmoid_x = 1.0f / (1.0f + hls::exp(-bn_out));
                float silu_out = bn_out * sigmoid_x;

                float q = silu_out / output_scale;
                int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
                if (y_int > 127) y_int = 127;
                if (y_int < -128) y_int = -128;
                output[c][h][w] = y_int;
            }
        }
    }
}