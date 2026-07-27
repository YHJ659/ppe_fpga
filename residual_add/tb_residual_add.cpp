#include "ap_int.h"
#include <cstdio>
#include <cstdlib>
#include <iostream>

#define CH   64
#define H    40
#define W    40

#define X_SCALE       0.03178280357300766f
#define FX_SCALE      0.018300835541852817f
#define OUTPUT_SCALE  0.03621446429275152f

void residual_add(
    ap_int<8>  x_input[CH][H][W],
    ap_int<8>  fx_input[CH][H][W],
    float      x_scale,
    float      fx_scale,
    float      output_scale,
    ap_int<8>  output[CH][H][W]
);

int main() {
    static ap_int<8> x_input[CH][H][W];
    static ap_int<8> fx_input[CH][H][W];
    static ap_int<8> output[CH][H][W];
    static int       golden[CH][H][W];

    // x_input.bin 읽기
    FILE *fx1 = fopen("x_input.bin", "rb");
    if (!fx1) { std::cout << "x_input.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    int32_t tmp;
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fx1);
                x_input[c][h][w] = tmp;
            }
    fclose(fx1);

    // fx_input.bin 읽기
    FILE *fx2 = fopen("fx_input.bin", "rb");
    if (!fx2) { std::cout << "fx_input.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fx2);
                fx_input[c][h][w] = tmp;
            }
    fclose(fx2);

    // golden_output.bin 읽기
    FILE *fg = fopen("golden_output.bin", "rb");
    if (!fg) { std::cout << "golden_output.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp, sizeof(int32_t), 1, fg);
                golden[c][h][w] = tmp;
            }
    fclose(fg);

    // 실제 하드웨어 로직 실행
    residual_add(x_input, fx_input, X_SCALE, FX_SCALE, OUTPUT_SCALE, output);

    // 비교 (bn_silu와 동일하게 오차범위 ±1 허용 — 부동소수점 반올림 오차 감안)
    int error_count = 0;
    const int TOLERANCE = 1;
    for (int c = 0; c < CH; c++)
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