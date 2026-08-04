#include "ap_int.h"
#include "hls_stream.h"
#include <thread>
#include <cstdio>

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

void bottleneck_router(
    hls::stream<pix8_t> &y1_s, hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_out_s,
    hls::stream<pix8_t> &conv_in_s, hls::stream<pix8_t> &res_x_s, hls::stream<pix8_t> &res_fx_s,
    hls::stream<pix8_t> &y2_out_s, hls::stream<pix8_t> &y3_out_s
);
void dummy_conv3x3(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s);
void dummy_bn_silu(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s);
void dummy_residual_add(hls::stream<pix8_t> &x_s, hls::stream<pix8_t> &fx_s, hls::stream<pix8_t> &out_s);



int main() {
    // ---- 스트림 선언: 라우터 8개 포트 + 고정 배선 1개(conv->bn) ----
    hls::stream<pix8_t> y1_s("y1_s"), bn_out_s("bn_out_s"), res_out_s("res_out_s");
    hls::stream<pix8_t> conv_in_s("conv_in_s"), res_x_s("res_x_s"), res_fx_s("res_fx_s");
    hls::stream<pix8_t> y2_out_s("y2_out_s"), y3_out_s("y3_out_s");
    hls::stream<pix8_t> conv_out_s("conv_out_s");  // dummy_conv3x3 -> dummy_bn_silu (고정 배선, 라우터 안 거침)

    // ---- 입력 패턴 생성: x1[c][h][w] = (c + h + w) % 30 (작게 유지해 오버플로 흔적을 보기 쉽게) ----
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

    // ---- 실제 하드웨어처럼 라우터/더미들을 동시에(스레드로) 실행 ----
    // 각자 blocking read로 서로를 기다립니다 — 이게 실제 Vivado에서
    // 독립된 IP들이 스트림으로 맞물려 도는 것과 같은 상황입니다.
    std::thread t_router(bottleneck_router,
        std::ref(y1_s), std::ref(bn_out_s), std::ref(res_out_s),
        std::ref(conv_in_s), std::ref(res_x_s), std::ref(res_fx_s),
        std::ref(y2_out_s), std::ref(y3_out_s));
    std::thread t_conv(dummy_conv3x3, std::ref(conv_in_s), std::ref(conv_out_s));
    std::thread t_bn(dummy_bn_silu, std::ref(conv_out_s), std::ref(bn_out_s));
    std::thread t_res(dummy_residual_add, std::ref(res_x_s), std::ref(res_fx_s), std::ref(res_out_s));

    t_router.join();
    t_conv.join();
    t_bn.join();
    t_res.join();

    // ---- 예상값을 손으로 계산 (더미들의 산술을 그대로 재현) ----
    // conv:+1, bn:+10 을 두 번, 마지막에 shortcut과 더함 — router.cpp
    // 주석의 10단계 그대로입니다. ap_int<8>로 계산해 하드웨어와 동일한
    // 오버플로/래핑 동작을 재현합니다.
    static ap_int<8> y2_exp[CH][H][W], y3_exp[CH][H][W];
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                ap_int<8> v0 = x1[c][h][w];
                ap_int<8> conv1 = v0 + 1;
                ap_int<8> bn1   = conv1 + 10;
                ap_int<8> conv2 = bn1 + 1;
                ap_int<8> bn2   = conv2 + 10;
                ap_int<8> y2    = v0 + bn2;          // residual: shortcut(v0) + fx(bn2)

                ap_int<8> conv3 = y2 + 1;
                ap_int<8> bn3   = conv3 + 10;
                ap_int<8> conv4 = bn3 + 1;
                ap_int<8> bn4   = conv4 + 10;
                ap_int<8> y3    = y2 + bn4;          // residual: shortcut(y2) + fx(bn4)

                y2_exp[c][h][w] = y2;
                y3_exp[c][h][w] = y3;
            }

    // ---- 라우터가 실제로 내보낸 y2/y3와 비교 ----
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

    printf(errors == 0 ? "TEST PASSED (라우터 순서/데이터 정합성 확인됨)\n"
                        : "TEST FAILED: %d mismatches\n", errors);
    return errors ? 1 : 0;
}
