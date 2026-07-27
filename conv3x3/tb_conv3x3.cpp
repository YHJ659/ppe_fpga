#include "ap_int.h"
#include <cstdio>
#include <cstdlib>
#include <iostream>

#define IN_CH   64
#define OUT_CH  64
#define IN_H    40
#define IN_W    40
#define K       3

void conv3x3(
    ap_int<8> input[IN_CH][IN_H][IN_W],
    ap_int<8> weight[OUT_CH][IN_CH][K][K],
    ap_int<32> output[OUT_CH][IN_H][IN_W]
);

int main() {
    static ap_int<8> input[IN_CH][IN_H][IN_W];
    static ap_int<8> weight[OUT_CH][IN_CH][K][K];
    static ap_int<32> output[OUT_CH][IN_H][IN_W];
    static long long golden[OUT_CH][IN_H][IN_W];

    // input.bin 읽기 (int32로 저장했으니 int32로 읽고 ap_int<8>에 대입)
    FILE *fin = fopen("input.bin", "rb");
    int32_t tmp;
    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < IN_H; h++)
            for (int w = 0; w < IN_W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fin);
                input[c][h][w] = tmp;
            }
    fclose(fin);

    // weight.bin 읽기
    FILE *fw = fopen("weight.bin", "rb");
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int ic = 0; ic < IN_CH; ic++)
            for (int kh = 0; kh < K; kh++)
                for (int kw = 0; kw < K; kw++) {
                    fread(&tmp, sizeof(int32_t), 1, fw);
                    weight[oc][ic][kh][kw] = tmp;
                }
    fclose(fw);

    // golden_output.bin 읽기 (int64로 저장했음)
    FILE *fg = fopen("golden_output.bin", "rb");
    int64_t gtmp;
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int h = 0; h < IN_H; h++)
            for (int w = 0; w < IN_W; w++) {
                fread(&gtmp, sizeof(int64_t), 1, fg);
                golden[oc][h][w] = gtmp;
            }
    fclose(fg);

    // 실제 하드웨어 로직(conv3x3) 실행
    conv3x3(input, weight, output);

    // 비교
    int error_count = 0;
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int h = 0; h < IN_H; h++)
            for (int w = 0; w < IN_W; w++) {
                if (output[oc][h][w] != golden[oc][h][w]) {
                    if (error_count < 10) {  // 앞에서 10개만 출력
                        std::cout << "MISMATCH at [" << oc << "][" << h << "][" << w << "]: "
                                  << "got " << output[oc][h][w].to_int()
                                  << ", expected " << golden[oc][h][w] << std::endl;
                    }
                    error_count++;
                }
            }

    if (error_count == 0) {
        std::cout << "TEST PASSED: 모든 출력이 golden reference와 일치합니다." << std::endl;
        return 0;
    } else {
        std::cout << "TEST FAILED: " << error_count << "개 불일치 발견." << std::endl;
        return 1;
    }
}