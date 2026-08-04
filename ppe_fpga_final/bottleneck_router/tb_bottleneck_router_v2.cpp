#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// router의 STEP 함수들 (bottleneck_router_split.cpp, external linkage)
void step1(hls::stream<pix8_t> &y1_s, hls::stream<pix8_t> &conv_in_s);
void step2(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &conv_in_s);
void step3_4(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_fx_s, hls::stream<pix8_t> &res_x_s);
void step5(hls::stream<pix8_t> &res_out_s, hls::stream<pix8_t> &y2_out_s);
void step6(hls::stream<pix8_t> &conv_in_s);
void step7(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &conv_in_s);
void step8_9(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_fx_s, hls::stream<pix8_t> &res_x_s);
void step10(hls::stream<pix8_t> &res_out_s, hls::stream<pix8_t> &y3_out_s);

void dummy_conv3x3(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s);
void dummy_bn_silu(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s);
void dummy_residual_add(hls::stream<pix8_t> &x_s, hls::stream<pix8_t> &fx_s, hls::stream<pix8_t> &out_s);

int main() {
    // 스트림은 이제 여러 스레드가 아니라 "한 스레드가 순서대로"
    // 쓰고 읽으므로, C-sim의 무한 FIFO 동작만으로 충분합니다.
    hls::stream<pix8_t> y1_s("y1_s"), bn_out_s("bn_out_s"), res_out_s("res_out_s");
    hls::stream<pix8_t> conv_in_s("conv_in_s"), res_x_s("res_x_s"), res_fx_s("res_fx_s");
    hls::stream<pix8_t> y2_out_s("y2_out_s"), y3_out_s("y3_out_s");
    hls::stream<pix8_t> conv_out_s("conv_out_s");  // dummy_conv3x3 -> dummy_bn_silu 고정 배선

    static ap_int<8> x1[CH][H][W];
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++)
                x1[c][h][w] = (c + h + w) % 30;

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix8_t px;
            for (int c = 0; c < CH; c++) px.ch[c] = x1[c][h][w];
            y1_s.write(px);
        }
    }

    // ---- 데이터 의존성 순서 그대로, 한 스레드에서 호출 ----
    // (Bottleneck1)
    step1(y1_s, conv_in_s);                          // y1 -> conv_in
    dummy_conv3x3(conv_in_s, conv_out_s);             // conv1
    dummy_bn_silu(conv_out_s, bn_out_s);              // bn1
    step2(bn_out_s, conv_in_s);                       // bn1_out -> conv_in (루프백)
    dummy_conv3x3(conv_in_s, conv_out_s);             // conv2
    dummy_bn_silu(conv_out_s, bn_out_s);              // bn2
    step3_4(bn_out_s, res_fx_s, res_x_s);             // bn2_out+shortcut -> residual_add 입력
    dummy_residual_add(res_x_s, res_fx_s, res_out_s); // Bottleneck1 결과 = y2
    step5(res_out_s, y2_out_s);                       // y2 -> concat + 버퍼 저장

    // (Bottleneck2)
    step6(conv_in_s);                                 // y2_buf -> conv_in
    dummy_conv3x3(conv_in_s, conv_out_s);
    dummy_bn_silu(conv_out_s, bn_out_s);
    step7(bn_out_s, conv_in_s);                       // 루프백
    dummy_conv3x3(conv_in_s, conv_out_s);
    dummy_bn_silu(conv_out_s, bn_out_s);
    step8_9(bn_out_s, res_fx_s, res_x_s);
    dummy_residual_add(res_x_s, res_fx_s, res_out_s); // Bottleneck2 결과 = y3
    step10(res_out_s, y3_out_s);                      // y3 -> concat

    // ---- 예상값 계산 (이전과 동일한 산술) ----
    static ap_int<8> y2_exp[CH][H][W], y3_exp[CH][H][W];
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                ap_int<8> v0 = x1[c][h][w];
                ap_int<8> conv1 = v0 + 1;
                ap_int<8> bn1   = conv1 + 10;
                ap_int<8> conv2 = bn1 + 1;
                ap_int<8> bn2   = conv2 + 10;
                ap_int<8> y2    = v0 + bn2;

                ap_int<8> conv3 = y2 + 1;
                ap_int<8> bn3   = conv3 + 10;
                ap_int<8> conv4 = bn3 + 1;
                ap_int<8> bn4   = conv4 + 10;
                ap_int<8> y3    = y2 + bn4;

                y2_exp[c][h][w] = y2;
                y3_exp[c][h][w] = y3;
            }

    int errors = 0;
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix8_t y2_got = y2_out_s.read();
            pix8_t y3_got = y3_out_s.read();
            for (int c = 0; c < CH; c++) {
                if (y2_got.ch[c] != y2_exp[c][h][w]) {
                    if (errors < 10) printf("y2 mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y2_got.ch[c], (int)y2_exp[c][h][w]);
                    errors++;
                }
                if (y3_got.ch[c] != y3_exp[c][h][w]) {
                    if (errors < 10) printf("y3 mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y3_got.ch[c], (int)y3_exp[c][h][w]);
                    errors++;
                }
            }
        }
    }

    printf(errors == 0 ? "TEST PASSED\n" : "TEST FAILED: %d mismatches\n", errors);
    return errors ? 1 : 0;
}