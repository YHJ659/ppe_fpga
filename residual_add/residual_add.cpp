#include "ap_int.h"

#define CH   64
#define H    40
#define W    40

void residual_add(
    ap_int<8>  x_input[CH][H][W],       // Shortcut 경로 (원본 입력)
    ap_int<8>  fx_input[CH][H][W],      // conv+BN+SiLU를 거친 결과 F(x)
    float      x_scale,                  // x_input의 양자화 스케일
    float      fx_scale,                 // fx_input의 양자화 스케일
    float      output_scale,             // 최종 출력 양자화 스케일
    ap_int<8>  output[CH][H][W]
) {
#pragma HLS INTERFACE bram port=x_input
#pragma HLS INTERFACE bram port=fx_input
#pragma HLS INTERFACE bram port=output
#pragma HLS INTERFACE s_axilite port=x_scale
#pragma HLS INTERFACE s_axilite port=fx_scale
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return

    for (int c = 0; c < CH; c++) {
        for (int h = 0; h < H; h++) {
            for (int w = 0; w < W; w++) {
#pragma HLS PIPELINE II=1
                // 역양자화 (각자 다른 스케일로)
                float x_float  = x_input[c][h][w].to_float()  * x_scale;
                float fx_float = fx_input[c][h][w].to_float() * fx_scale;

                // 잔차 덧셈 (실제 float 물리량 기준)
                float sum = x_float + fx_float;

                // 재양자화
                float q = sum / output_scale;
                int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
                if (y_int > 127) y_int = 127;
                if (y_int < -128) y_int = -128;
                output[c][h][w] = y_int;
            }
        }
    }
}