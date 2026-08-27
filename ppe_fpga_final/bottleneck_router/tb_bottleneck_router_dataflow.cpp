#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// 합성 대상 top function을 직접 호출합니다 (cosim이 요구하는 부분).
void bottleneck_router(
    hls::stream<pix8_t> &y1_s, hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_out_s,
    hls::stream<pix8_t> &conv_in_s, hls::stream<pix8_t> &res_x_s, hls::stream<pix8_t> &res_fx_s,
    hls::stream<pix8_t> &y2_out_s, hls::stream<pix8_t> &y3_out_s
);

static void write_pixel(hls::stream<pix8_t> &s, ap_int<8> v[CH][H][W], int h, int w) {
    pix8_t px;
    for (int c = 0; c < CH; c++) px.ch[c] = v[c][h][w];
    s.write(px);
}

// conv_in_s / res_x_s / res_fx_s 를 읽어서, 기대 배열과 일치하는지 확인.
// (Co-simulation에서 이 포트들을 아무도 안 읽으면 FIFO가 가득 차서
//  회로가 영원히 멈춘다 — 이건 실제 conv3x3/residual_add IP가 하는
//  일을 테스트벤치가 대신 흉내내는 것뿐이다.)
static int check_stream(const char *name, hls::stream<pix8_t> &s,
                         ap_int<8> expect[CH][H][W]) {
    int errors = 0;
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix8_t got = s.read();
            for (int c = 0; c < CH; c++) {
                if (got.ch[c] != expect[c][h][w]) {
                    if (errors < 5) printf("%s mismatch [%d][%d][%d]: got %d, expected %d\n",
                        name, c, h, w, (int)got.ch[c], (int)expect[c][h][w]);
                    errors++;
                }
            }
        }
    }
    return errors;
}

int main() {
    hls::stream<pix8_t> y1_s("y1_s"), bn_out_s("bn_out_s"), res_out_s("res_out_s");
    hls::stream<pix8_t> conv_in_s("conv_in_s"), res_x_s("res_x_s"), res_fx_s("res_fx_s");
    hls::stream<pix8_t> y2_out_s("y2_out_s"), y3_out_s("y3_out_s");

    // ---- 입력 패턴 ----
    static ap_int<8> x1[CH][H][W];
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++)
                x1[c][h][w] = (c + h + w) % 30;

    // ---- 더미 산술(conv:+1, bn:+10, residual:x+fx)을 그대로 손으로
    //      미리 계산해, 라우터가 4번 읽을 bn_out_s와 2번 읽을
    //      res_out_s의 "정확한 순서의 값들"을 구합니다. ----
    static ap_int<8> bn1_a[CH][H][W], bn2_a[CH][H][W];       // Bottleneck0의 두 bn 결과
    static ap_int<8> bn1b_a[CH][H][W], bn2b_a[CH][H][W];     // Bottleneck1의 두 bn 결과
    static ap_int<8> y2_a[CH][H][W], y3_a[CH][H][W];

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

                bn1_a[c][h][w]  = bn1;
                bn2_a[c][h][w]  = bn2;
                y2_a[c][h][w]   = y2;
                bn1b_a[c][h][w] = bn3;
                bn2b_a[c][h][w] = bn4;
                y3_a[c][h][w]   = y3;
            }

    // ---- y1_s: 그대로 (router가 실제로 읽는 입력) ----
    for (int h = 0; h < H; h++)
        for (int w = 0; w < W; w++)
            write_pixel(y1_s, x1, h, w);

    // ---- bn_out_s: router가 읽는 순서 그대로 미리 적재 ----
    for (int h = 0; h < H; h++) for (int w = 0; w < W; w++) write_pixel(bn_out_s, bn1_a,  h, w); // Bottleneck0 1차
    for (int h = 0; h < H; h++) for (int w = 0; w < W; w++) write_pixel(bn_out_s, bn2_a,  h, w); // Bottleneck0 2차
    for (int h = 0; h < H; h++) for (int w = 0; w < W; w++) write_pixel(bn_out_s, bn1b_a, h, w); // Bottleneck1 1차
    for (int h = 0; h < H; h++) for (int w = 0; w < W; w++) write_pixel(bn_out_s, bn2b_a, h, w); // Bottleneck1 2차

    // ---- res_out_s: router가 읽는 순서 그대로 미리 적재 ----
    for (int h = 0; h < H; h++) for (int w = 0; w < W; w++) write_pixel(res_out_s, y2_a, h, w); // STEP5
    for (int h = 0; h < H; h++) for (int w = 0; w < W; w++) write_pixel(res_out_s, y3_a, h, w); // STEP10

    // ---- 합성 대상 top function을 실제로, 통째로 한 번 호출 ----
    bottleneck_router(y1_s, bn_out_s, res_out_s, conv_in_s, res_x_s, res_fx_s, y2_out_s, y3_out_s);

    int errors = 0;

    // ---- conv_in_s 검증: 순서대로 x1 -> bn1_a -> y2_a -> bn1b_a (4*N_PIX) ----
    errors += check_stream("conv_in_s(m0.cv1)", conv_in_s, x1);
    errors += check_stream("conv_in_s(m0.cv2)", conv_in_s, bn1_a);
    errors += check_stream("conv_in_s(m1.cv1)", conv_in_s, y2_a);
    errors += check_stream("conv_in_s(m1.cv2)", conv_in_s, bn1b_a);

    // ---- res_x_s 검증: shortcut 값 -> x1(Bottleneck0), y2_a(Bottleneck1) ----
    errors += check_stream("res_x_s(bn0)", res_x_s, x1);
    errors += check_stream("res_x_s(bn1)", res_x_s, y2_a);

    // ---- res_fx_s 검증: 2차 conv 결과 -> bn2_a(Bottleneck0), bn2b_a(Bottleneck1) ----
    errors += check_stream("res_fx_s(bn0)", res_fx_s, bn2_a);
    errors += check_stream("res_fx_s(bn1)", res_fx_s, bn2b_a);

    // ---- 결과 확인: y2_out_s/y3_out_s가 예상과 같은지 ----
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix8_t y2_got = y2_out_s.read();
            pix8_t y3_got = y3_out_s.read();
            for (int c = 0; c < CH; c++) {
                if (y2_got.ch[c] != y2_a[c][h][w]) {
                    if (errors < 10) printf("y2 mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y2_got.ch[c], (int)y2_a[c][h][w]);
                    errors++;
                }
                if (y3_got.ch[c] != y3_a[c][h][w]) {
                    if (errors < 10) printf("y3 mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y3_got.ch[c], (int)y3_a[c][h][w]);
                    errors++;
                }
            }
        }
    }

    printf(errors == 0 ? "TEST PASSED\n" : "TEST FAILED: %d mismatches\n", errors);
    return errors ? 1 : 0;
}
