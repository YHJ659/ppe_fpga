#include "ap_int.h"
#include <cstdio>
#include <cstdlib>
#include <iostream>

#define CH   128
#define H    40
#define W    40

// Python 스크립트(scales.txt)에서 확인한 실제 양자화 스케일 값
#define INPUT_SCALE   0.03091546118728758f
#define WEIGHT_SCALE  0.0029566006397637795f
#define OUTPUT_SCALE  0.04751440108291746f

void bn_silu_128(
    ap_int<32> conv_out[CH][H][W],
    float      bn_scale[CH],
    float      bn_shift[CH],
    float      input_scale,
    float      weight_scale,
    float      output_scale,
    ap_int<8>  output[CH][H][W]
);

int main() {
    static ap_int<32> conv_out[CH][H][W];
    static float       bn_scale[CH];
    static float       bn_shift[CH];
    static ap_int<8>   output[CH][H][W];
    static int         golden[CH][H][W];

    // conv_out.bin 읽기 (conv3x3의 raw INT32 출력)
    FILE *f_conv = fopen("conv_out.bin", "rb");
    if (!f_conv) { std::cout << "conv_out.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    int32_t tmp32;
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp32, sizeof(int32_t), 1, f_conv);
                conv_out[c][h][w] = tmp32;
            }
    fclose(f_conv);

    // bn_scale.bin 읽기 (float32, 채널별 1개씩)
    FILE *f_scale = fopen("bn_scale.bin", "rb");
    if (!f_scale) { std::cout << "bn_scale.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < CH; c++)
        fread(&bn_scale[c], sizeof(float), 1, f_scale);
    fclose(f_scale);

    // bn_shift.bin 읽기
    FILE *f_shift = fopen("bn_shift.bin", "rb");
    if (!f_shift) { std::cout << "bn_shift.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < CH; c++)
        fread(&bn_shift[c], sizeof(float), 1, f_shift);
    fclose(f_shift);

    // golden_output.bin 읽기 (INT8 결과를 INT32로 저장했다고 가정 — Python 저장 방식에 맞춰 조정 필요)
    FILE *f_golden = fopen("golden_output.bin", "rb");
    if (!f_golden) { std::cout << "golden_output.bin 파일을 열 수 없습니다." << std::endl; return 1; }
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                fread(&tmp32, sizeof(int32_t), 1, f_golden);
                golden[c][h][w] = tmp32;
            }
    fclose(f_golden);

    // 실제 하드웨어 로직(bn_silu) 실행
    bn_silu_128(conv_out, bn_scale, bn_shift, INPUT_SCALE, WEIGHT_SCALE, OUTPUT_SCALE, output);

    // 비교 (부동소수점 연산이 섞여 있어 완전히 정수처럼 딱 맞지 않을 수 있음 -> 오차 허용 범위 둠)
    int error_count = 0;
    const int TOLERANCE = 1;  // INT8 양자화 반올림 오차 허용 범위 (±1)
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