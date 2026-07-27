#include "ap_int.h"

// ===== model.6 C2f 블록의 cv1 (1x1 Conv) 기준 =====
// model.6.cv1.conv.weight: [128, 128, 1, 1]
#define IN_CH   128
#define OUT_CH  128
#define IN_H    40
#define IN_W    40

void conv1x1(
    ap_int<8>  input[IN_CH][IN_H][IN_W],
    ap_int<8>  weight[OUT_CH][IN_CH],
    ap_int<32> output[OUT_CH][IN_H][IN_W]
) {
#pragma HLS INTERFACE bram port=input
#pragma HLS INTERFACE bram port=weight
#pragma HLS INTERFACE bram port=output

    // ----- 로컬 버퍼 (여기에만 파티셔닝 적용, 최상위 포트는 단순 유지) -----
    static ap_int<8> local_input[IN_CH][IN_H][IN_W];
    static ap_int<8> local_weight[OUT_CH][IN_CH];
#pragma HLS ARRAY_PARTITION variable=local_weight cyclic factor=16 dim=2
#pragma HLS ARRAY_PARTITION variable=local_input  cyclic factor=16 dim=1

    // 입력 복사 (BRAM -> 파티션된 로컬 버퍼)
    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < IN_H; h++)
            for (int w = 0; w < IN_W; w++)
                local_input[c][h][w] = input[c][h][w];

    // 가중치 복사
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int ic = 0; ic < IN_CH; ic++)
            local_weight[oc][ic] = weight[oc][ic];

    // ----- 실제 1x1 Conv 연산 -----
    for (int oc = 0; oc < OUT_CH; oc++) {
        for (int oh = 0; oh < IN_H; oh++) {
            for (int ow = 0; ow < IN_W; ow++) {
#pragma HLS PIPELINE II=4
                ap_int<32> sum = 0;
                for (int ic = 0; ic < IN_CH; ic++) {
                    sum += local_input[ic][oh][ow] * local_weight[oc][ic];
                }
                output[oc][oh][ow] = sum;
            }
        }
    }
}