#include "ap_int.h"
#include <cstdio>
#include <iostream>

#define CH_PER_BRANCH  64
#define NUM_BRANCH     4
#define OUT_CH         256
#define H              40
#define W              40

#define Y0_SCALE      0.047591093018299016f
#define Y1_SCALE      0.03178280357300766f
#define Y2_SCALE      0.03628666945329801f
#define Y3_SCALE      0.04050143309465543f
#define OUTPUT_SCALE  0.047591093018299016f

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
);

void read_bin(const char* filename, ap_int<8> arr[CH_PER_BRANCH][H][W]) {
    FILE *f = fopen(filename, "rb");
    if (!f) { std::cout << filename << " 파일을 열 수 없습니다." << std::endl; exit(1); }
    int32_t tmp;
    for (int c = 0; c < CH_PER_BRANCH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, f);
                arr[c][h][w] = tmp;
            }
    fclose(f);
}

int main() {
    static ap_int<8> y0[CH_PER_BRANCH][H][W];
    static ap_int<8> y1[CH_PER_BRANCH][H][W];
    static ap_int<8> y2[CH_PER_BRANCH][H][W];
    static ap_int<8> y3[CH_PER_BRANCH][H][W];
    static ap_int<8> output[OUT_CH][H][W];
    static int        golden[OUT_CH][H][W];

    read_bin("y0.bin", y0);
    read_bin("y1.bin", y1);
    read_bin("y2.bin", y2);
    read_bin("y3.bin", y3);

    FILE *fg = fopen("golden_output.bin", "rb");
    if (!fg) { std::cout << "golden_output.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    int32_t tmp;
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fg);
                golden[c][h][w] = tmp;
            }
    fclose(fg);

    concat_channel(y0, y1, y2, y3, Y0_SCALE, Y1_SCALE, Y2_SCALE, Y3_SCALE, OUTPUT_SCALE, output);

    int error_count = 0;
    const int TOLERANCE = 1;
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int diff = output[c][h][w].to_int() - golden[c][h][w];
                if (diff < 0) diff = -diff;
                if (diff > TOLERANCE) {
                    if (error_count < 10) {
                        std::cout << "MISMATCH at [" << c << "][" << h << "][" << w << "]: "
                                  << "got " << output[c][h][w].to_int()
                                  << ", expected " << golden[c][h][w]
                                  << " (diff=" << diff << ")" << std::endl;
                    }
                    error_count++;
                }
            }

    if (error_count == 0) {
        std::cout << "TEST PASSED: 모든 출력이 golden reference와 오차범위(±" << TOLERANCE << ") 내에서 일치합니다." << std::endl;
        return 0;
    } else {
        std::cout << "TEST FAILED: " << error_count << "개 불일치 발견." << std::endl;
        return 1;
    }
}