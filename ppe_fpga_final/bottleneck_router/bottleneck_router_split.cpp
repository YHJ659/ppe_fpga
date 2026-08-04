#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// ============================================================
//  10단계를 각각 이름 붙은 함수로 분리했습니다. bottleneck_router()
//  최상위 함수가 이 10개를 순서대로 부르는 구조라, 합성되는
//  하드웨어는 이전 버전과 완전히 동일합니다 (동작 변화 없음).
//
//  이렇게 나눈 이유: 테스트벤치가 std::thread 없이, 이 함수들을
//  더미 IP들과 번갈아 "한 스레드에서 순서대로" 호출할 수 있게
//  하기 위해서입니다. hls::stream을 여러 OS 스레드가 동시에
//  건드리면 내부 컨테이너가 깨질 수 있다는 게 확인됐습니다
//  (double free or corruption) — 애초에 동시 접근 자체를
//  없애는 게 가장 확실한 해법입니다.
//
//  y1_buf/y2_buf는 여러 STEP 함수에 걸쳐 값이 유지돼야 하므로
//  static으로 선언합니다.
// ============================================================

static ap_int<8> y1_buf[CH][H][W];
static ap_int<8> y2_buf[CH][H][W];

void step1(hls::stream<pix8_t> &y1_s, hls::stream<pix8_t> &conv_in_s) {
    for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = y1_s.read();
        conv_in_s.write(px);
        for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y1_buf[c][h][w] = px.ch[c];
        }
    }
}

void step2(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &conv_in_s) {
    for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        conv_in_s.write(bn_out_s.read());
    }
}

void step3_4(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_fx_s,
             hls::stream<pix8_t> &res_x_s) {
    for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            xp.ch[c] = y1_buf[c][h][w];
        }
        res_x_s.write(xp);
    }
}

void step5(hls::stream<pix8_t> &res_out_s, hls::stream<pix8_t> &y2_out_s) {
    for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = res_out_s.read();
        y2_out_s.write(px);
        for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y2_buf[c][h][w] = px.ch[c];
        }
    }
}

void step6(hls::stream<pix8_t> &conv_in_s) {
    for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px;
        for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            px.ch[c] = y2_buf[c][h][w];
        }
        conv_in_s.write(px);
    }
}

void step7(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &conv_in_s) {
    for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        conv_in_s.write(bn_out_s.read());
    }
}

void step8_9(hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_fx_s,
             hls::stream<pix8_t> &res_x_s) {
    for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            xp.ch[c] = y2_buf[c][h][w];
        }
        res_x_s.write(xp);
    }
}

void step10(hls::stream<pix8_t> &res_out_s, hls::stream<pix8_t> &y3_out_s) {
    for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        y3_out_s.write(res_out_s.read());
    }
}

void bottleneck_router(
    hls::stream<pix8_t> &y1_s, hls::stream<pix8_t> &bn_out_s, hls::stream<pix8_t> &res_out_s,
    hls::stream<pix8_t> &conv_in_s, hls::stream<pix8_t> &res_x_s, hls::stream<pix8_t> &res_fx_s,
    hls::stream<pix8_t> &y2_out_s, hls::stream<pix8_t> &y3_out_s
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

    step1(y1_s, conv_in_s);
    step2(bn_out_s, conv_in_s);
    step3_4(bn_out_s, res_fx_s, res_x_s);
    step5(res_out_s, y2_out_s);
    step6(conv_in_s);
    step7(bn_out_s, conv_in_s);
    step8_9(bn_out_s, res_fx_s, res_x_s);
    step10(res_out_s, y3_out_s);
}