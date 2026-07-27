####original
#include "ap_int.h"

// ===== model.6 C2f 블록의 Bottleneck 내부 3x3 Conv 기준 =====
// 채널: Bottleneck 내부는 C2f 입력(128)의 절반인 64채널
// (model.6.m.0.cv1.conv.weight: [64, 64, 3, 3] 참고)
#define IN_CH   64
#define OUT_CH  64
#define IN_H    40      // 640x640 입력 기준 (hook으로 재확인 필요)
#define IN_W    40
#define K       3
#define PAD     1       // same padding (입출력 크기 동일 유지)

void conv3x3(
    ap_int<8>  input[IN_CH][IN_H][IN_W],
    ap_int<8>  weight[OUT_CH][IN_CH][K][K],
    ap_int<32> output[OUT_CH][IN_H][IN_W]
) {

#pragma HLS ARRAY_PARTITION variable=weight complete dim=3
#pragma HLS ARRAY_PARTITION variable=weight complete dim=4
#pragma HLS ARRAY_PARTITION variable=weight cyclic factor=8 dim=2
#pragma HLS ARRAY_PARTITION variable=input cyclic factor=3 dim=2
#pragma HLS ARRAY_PARTITION variable=input cyclic factor=3 dim=3
#pragma HLS ARRAY_PARTITION variable=input cyclic factor=8 dim=1

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
                                sum += input[ic][ih][iw] * weight[oc][ic][kh][kw];
                            }
                        }
                    }
                }
                output[oc][oh][ow] = sum;
            }
        }
    }
}