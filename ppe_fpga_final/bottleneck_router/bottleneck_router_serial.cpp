#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// ============================================================
//  10단계 순서는 이전 버전과 동일합니다 (bottleneck_router.cpp 참고).
//
//  ★ 이번 변경: y1_buf/y2_buf 접근을 64-way 병렬(UNROLL)에서
//  채널 직렬 처리로 바꿨습니다. bn_silu에서 검증된 패턴
//  (t = pixel*CH + c 단일 카운터)을 그대로 가져왔습니다.
//  라우터는 latency 여유가 매우 커서(0.128ms vs 병목 conv3x3의
//  약 50ms), 이 변경으로 latency가 수십 배 늘어도 전체 시스템에는
//  영향이 없고, LUT만 확실히 줄어들 것으로 기대합니다.
// ============================================================
void bottleneck_router(
    hls::stream<pix8_t> &y1_s,        // split.y1
    hls::stream<pix8_t> &bn_out_s,    // bn_silu_64.out_s
    hls::stream<pix8_t> &res_out_s,   // residual_add.out_s

    hls::stream<pix8_t> &conv_in_s,   // -> conv3x3.in_s
    hls::stream<pix8_t> &res_x_s,     // -> residual_add.x_s (shortcut)
    hls::stream<pix8_t> &res_fx_s,    // -> residual_add.fx_s
    hls::stream<pix8_t> &y2_out_s,    // -> concat.y2_s
    hls::stream<pix8_t> &y3_out_s     // -> concat.y3_s
) {
#pragma HLS INTERFACE axis port=y1_s
#pragma HLS INTERFACE axis port=bn_out_s
#pragma HLS INTERFACE axis port=res_out_s
#pragma HLS INTERFACE axis port=conv_in_s
#pragma HLS INTERFACE axis port=res_x_s
#pragma HLS INTERFACE axis port=res_fx_s
#pragma HLS INTERFACE axis port=y2_out_s
#pragma HLS INTERFACE axis port=y3_out_s
#pragma HLS INTERFACE s_axilite port=return

    // y1, y2를 프레임 전체 붙잡아둡니다. 채널 방향을 더 이상 병렬로
    // 안 쪼개니 파티션도 필요 없습니다 — 사이클마다 원소 1개만
    // 접근하므로 기본 BRAM 포트(2개)로 충분합니다.
	static ap_int<8> y1_buf[CH][H][W];
	static ap_int<8> y2_buf[CH][H][W];

    // 픽셀 언팩/팩용 소형 레지스터 (bn_silu와 동일한 더블 버퍼 없이도
    // 충분합니다 — 여기선 II=1을 목표로 하지 않고 자원 최소화가
    // 목적이라, 픽셀 경계마다 조금 쉬어가도 무방합니다).
    ap_int<8> pxv[CH];

    // ---- 1) y1 도착: conv3x3로 전달하면서 동시에 버퍼에 저장 ----
    // 채널 하나씩 순차로 y1_buf에 씁니다.
    STEP1: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = y1_s.read();
        conv_in_s.write(px);
        STEP1_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y1_buf[c][h][w] = px.ch[c];
        }
    }

    // ---- 2) bn_out(conv1 결과) 도착: 루프백해서 conv3x3로 다시 ----
    STEP2: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        conv_in_s.write(bn_out_s.read());
    }

    // ---- 3,4) bn_out(conv2 결과) + y1_buf(shortcut) -> residual_add ----
    STEP3_4: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        STEP3_4_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            xp.ch[c] = y1_buf[c][h][w];
        }
        res_x_s.write(xp);
    }

    // ---- 5) residual_add 결과(y2) 도착: concat으로 + y2_buf에 저장 ----
    STEP5: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = res_out_s.read();
        y2_out_s.write(px);
        STEP5_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y2_buf[c][h][w] = px.ch[c];
        }
    }

    // ---- 6) y2_buf -> conv3x3 (Bottleneck2의 conv1 입력) ----
    STEP6: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px;
        STEP6_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            px.ch[c] = y2_buf[c][h][w];
        }
        conv_in_s.write(px);
    }

    // ---- 7) bn_out(conv1 결과) 루프백 ----
    STEP7: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        conv_in_s.write(bn_out_s.read());
    }

    // ---- 8,9) bn_out(conv2 결과) + y2_buf(shortcut) -> residual_add ----
    STEP8_9: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        STEP8_9_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            xp.ch[c] = y2_buf[c][h][w];
        }
        res_x_s.write(xp);
    }

    // ---- 10) residual_add 결과(y3) 도착: concat으로 (버퍼링 불필요) ----
    STEP10: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        y3_out_s.write(res_out_s.read());
    }
}
