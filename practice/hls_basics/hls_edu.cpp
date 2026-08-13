# terminal 창에 "vivado_hls" 친 이후에
# 해당 창에 코드 입력 후 synthesis 한 이후에 export하면 "export.zip"파일 생깁니다 해당 파일 압축해제 후 conv3x3_ip 폴더 생성하면
# ip이 됩니다 add ip로 block design 추가 하면 완성.

#conv3x3 
#include "ap_int.h"
#define IN_CH 64
#define OUT_CH 64
#define IN_H 34   // 입력 feature map 높이 (예시)
#define IN_W 34
#define K 3       // 커널 크기

void conv3x3(
    ap_int<8> input[IN_CH][IN_H][IN_W],
    ap_int<8> weight[OUT_CH][IN_CH][K][K],
    ap_int<32> output[OUT_CH][IN_H-2][IN_W-2]
) {
    for (int oc = 0; oc < OUT_CH; oc++) {
        for (int oh = 0; oh < IN_H-2; oh++) {
            for (int ow = 0; ow < IN_W-2; ow++) {
                ap_int<32> sum = 0;
                for (int ic = 0; ic < IN_CH; ic++) {
                    for (int kh = 0; kh < K; kh++) {
                        for (int kw = 0; kw < K; kw++) {
                            sum += input[ic][oh+kh][ow+kw] * weight[oc][ic][kh][kw];
                        }
                    }
                }
                output[oc][oh][ow] = sum;
            }
        }
    }
}


