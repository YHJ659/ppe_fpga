#include "ap_int.h"

#define IN_CH   64
#define OUT_CH  64
#define IN_H    40
#define IN_W    40
#define K       3
#define PAD     1

void conv3x3(
    ap_int<8>  input[IN_CH][IN_H][IN_W],
    ap_int<8>  weight[OUT_CH][IN_CH][K][K],
    ap_int<32> output[OUT_CH][IN_H][IN_W]
) {
#pragma HLS INTERFACE bram port=input
#pragma HLS INTERFACE bram port=weight
#pragma HLS INTERFACE bram port=output

    // 내부 로컬 버퍼 — 여기에만 파티셔닝 적용
    static ap_int<8> local_input[IN_CH][IN_H][IN_W];
    static ap_int<8> local_weight[OUT_CH][IN_CH][K][K];
#pragma HLS ARRAY_PARTITION variable=local_weight complete dim=3
#pragma HLS ARRAY_PARTITION variable=local_weight complete dim=4
#pragma HLS ARRAY_PARTITION variable=local_weight cyclic factor=8 dim=2
#pragma HLS ARRAY_PARTITION variable=local_input cyclic factor=3 dim=2
#pragma HLS ARRAY_PARTITION variable=local_input cyclic factor=3 dim=3
#pragma HLS ARRAY_PARTITION variable=local_input cyclic factor=8 dim=1

    // 입력을 로컬 버퍼로 복사 (BRAM → 파티션된 레지스터)
    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < IN_H; h++)
            for (int w = 0; w < IN_W; w++)
                local_input[c][h][w] = input[c][h][w];

    for (int oc = 0; oc < OUT_CH; oc++)
        for (int ic = 0; ic < IN_CH; ic++)
            for (int kh = 0; kh < K; kh++)
                for (int kw = 0; kw < K; kw++)
                    local_weight[oc][ic][kh][kw] = weight[oc][ic][kh][kw];

    // 이하 연산 로직은 local_input, local_weight 사용
    for (int oc = 0; oc < OUT_CH; oc++) {
        for (int oh = 0; oh < IN_H; oh++) {
            for (int ow = 0; ow < IN_W; ow++) {
#pragma HLS PIPELINE II=8
                ap_int<32> sum = 0;
                for (int ic = 0; ic < IN_CH; ic++) {
                    for (int kh = 0; kh < K; kh++) {
                        for (int kw = 0; kw < K; kw++) {
                            int ih = oh + kh - PAD;
                            int iw = ow + kw - PAD;
                            if (ih >= 0 && ih < IN_H && iw >= 0 && iw < IN_W) {
                                sum += local_input[ic][ih][iw] * local_weight[oc][ic][kh][kw];
                            }
                        }
                    }
                }
                output[oc][oh][ow] = sum;
            }
        }
    }
}
