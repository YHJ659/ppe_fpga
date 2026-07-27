#include "ap_int.h"
#include <cstdio>
#include <iostream>

#define IN_CH   128
#define OUT_CH  64
#define H       40
#define W       40

void split_channel(
    ap_int<8> input[IN_CH][H][W],
    ap_int<8> y0[OUT_CH][H][W],
    ap_int<8> y1[OUT_CH][H][W]
);

int main() {
    static ap_int<8> input[IN_CH][H][W];
    static ap_int<8> y0[OUT_CH][H][W];
    static ap_int<8> y1[OUT_CH][H][W];
    static int golden_y0[OUT_CH][H][W];
    static int golden_y1[OUT_CH][H][W];

    FILE *fin = fopen("input.bin", "rb");
    if (!fin) { std::cout << "input.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    int32_t tmp;
    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fin);
                input[c][h][w] = tmp;
            }
    fclose(fin);

    FILE *fg0 = fopen("golden_y0.bin", "rb");
    if (!fg0) { std::cout << "golden_y0.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fg0);
                golden_y0[c][h][w] = tmp;
            }
    fclose(fg0);

    FILE *fg1 = fopen("golden_y1.bin", "rb");
    if (!fg1) { std::cout << "golden_y1.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fg1);
                golden_y1[c][h][w] = tmp;
            }
    fclose(fg1);

    split_channel(input, y0, y1);

    int error_count = 0;
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                if (y0[c][h][w].to_int() != golden_y0[c][h][w]) {
                    if (error_count < 10)
                        std::cout << "Y0 MISMATCH at [" << c << "][" << h << "][" << w << "]" << std::endl;
                    error_count++;
                }
                if (y1[c][h][w].to_int() != golden_y1[c][h][w]) {
                    if (error_count < 10)
                        std::cout << "Y1 MISMATCH at [" << c << "][" << h << "][" << w << "]" << std::endl;
                    error_count++;
                }
            }

    if (error_count == 0) {
        std::cout << "TEST PASSED: Split 결과가 golden reference와 완전히 일치합니다." << std::endl;
        return 0;
    } else {
        std::cout << "TEST FAILED: " << error_count << "개 불일치 발견." << std::endl;
        return 1;
    }
}