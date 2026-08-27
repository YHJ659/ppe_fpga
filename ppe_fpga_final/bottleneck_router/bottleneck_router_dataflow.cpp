#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// ============================================================
//  ★ DATAFLOW 재작성판 (v5 — 영역 간 핸드오프도 URAM 배열로)
//
//  v4에서 데드락(멀티 생산자/소비자)은 해결됐지만, shortcut_0/1과
//  cv_mid_0/1을 hls::stream(depth=1600 또는 64)으로 만들어서
//  BRAM을 229개나 쓰는 낭비가 생겼다. 게다가 cv_mid_0/1은
//  depth=64인데 실제로는 "영역1이 1600개를 다 쓴 뒤에야 영역2가
//  읽기 시작하는" 순차적 핸드오프라서, y2_src가 그랬던 것과 똑같은
//  데드락 위험이 남아있었다(2x2 테스트에서는 depth와 프레임크기가
//  우연히 같아서 못 잡아냈다).
//
//  v5는 이 다섯 개(shortcut_0/1, cv_mid_0/1) 전부를, 이미 검증된
//  y2_buf와 완전히 같은 방식 — "한 DATAFLOW 영역이 다 쓰고, 그
//  다음(별개의, 순차적인) 영역이 다 읽는" URAM 배열 — 로 통일한다.
//  이러면 깊이 제한 자체가 없어져 데드락 위험이 원천적으로
//  사라지고, BRAM 대신 조밀한 URAM을 쓰게 되어 자원도 줄어든다.
// ============================================================

// ---- 외부 스트림(y1_s)에서 읽어 conv_in_s로 흘리며, 원본값을
//      shortcut 배열에도 저장 ----
static void feed_from_port(
    hls::stream<pix8_t> &src_s,
    hls::stream<pix8_t> &conv_in_s,
    ap_int<8> shortcut[CH][H][W]
) {
FEED: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
#pragma HLS PIPELINE II=1
        pix8_t px = src_s.read();
        conv_in_s.write(px);
        FEED_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            shortcut[c][h][w] = px.ch[c];
        }
    }
}

// ---- 내부 배열(cv_mid)에서 읽어 conv_in_s로 흘리기만 함 (shortcut 없음) ----
static void feed_only(
    ap_int<8> src[CH][H][W],
    hls::stream<pix8_t> &conv_in_s
) {
FEED_ONLY: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px;
        FEED_ONLY_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            px.ch[c] = src[c][h][w];
        }
#pragma HLS PIPELINE II=1
        conv_in_s.write(px);
    }
}

// ---- conv 결과(bn_out_s)를 다음 conv 입력용 배열(cv_mid)에 저장 ----
static void drain_to_array(
    hls::stream<pix8_t> &bn_out_s,
    ap_int<8> next[CH][H][W]
) {
DRAIN: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = bn_out_s.read();
#pragma HLS PIPELINE II=1
        DRAIN_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            next[c][h][w] = px.ch[c];
        }
    }
}

// ---- conv 결과(bn_out_s)를 res_fx_s로, shortcut 배열을 res_x_s로 짝지어 전달 ----
static void drain_to_residual(
    hls::stream<pix8_t> &bn_out_s,
    ap_int<8> shortcut[CH][H][W],
    hls::stream<pix8_t> &res_fx_s,
    hls::stream<pix8_t> &res_x_s
) {
DRAIN_RES: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
#pragma HLS PIPELINE II=1
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        DRAIN_RES_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            xp.ch[c] = shortcut[c][h][w];
        }
        res_x_s.write(xp);
    }
}

void bottleneck_router(
    hls::stream<pix8_t> &y1_s,        // split.y1
    hls::stream<pix8_t> &bn_out_s,    // bn_silu_64.out_s (하나의 물리 IP, 4회 재사용)
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

    // 전부 "한 영역이 다 쓰고, 다음(별개, 순차) 영역이 다 읽는"
    // 핸드오프용 URAM 배열이다 — 동시 실행되는 두 태스크가 공유하는
    // 게 아니므로 안전하다(y2_buf와 완전히 같은 패턴).
    static ap_int<8> shortcut_0[CH][H][W];
    static ap_int<8> cv_mid_0[CH][H][W];
    static ap_int<8> cv_mid_1[CH][H][W];
    static ap_int<8> y2_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=shortcut_0 cyclic factor=8 dim=3
#pragma HLS ARRAY_RESHAPE variable=cv_mid_0   cyclic factor=8 dim=3
#pragma HLS ARRAY_RESHAPE variable=cv_mid_1   cyclic factor=8 dim=3
#pragma HLS ARRAY_RESHAPE variable=y2_buf     cyclic factor=8 dim=3
#pragma HLS BIND_STORAGE variable=shortcut_0 type=ram_1p impl=uram
#pragma HLS BIND_STORAGE variable=cv_mid_0   type=ram_1p impl=uram
#pragma HLS BIND_STORAGE variable=cv_mid_1   type=ram_1p impl=uram
#pragma HLS BIND_STORAGE variable=y2_buf     type=ram_1p impl=uram

    // ================= [영역 1] m0.cv1 =================
    {
#pragma HLS DATAFLOW
        feed_from_port(y1_s, conv_in_s, shortcut_0);
        drain_to_array(bn_out_s, cv_mid_0);
    }

    // ================= [영역 2] m0.cv2 =================
    {
#pragma HLS DATAFLOW
        feed_only(cv_mid_0, conv_in_s);
        drain_to_residual(bn_out_s, shortcut_0, res_fx_s, res_x_s);
    }

    // ---- STEP5: residual_add 결과(y2) 도착 -> concat + y2_buf 저장 ----
STEP5: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
#pragma HLS PIPELINE II=1
        pix8_t px = res_out_s.read();
        y2_out_s.write(px);
        STEP5_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y2_buf[c][h][w] = px.ch[c];
        }
    }

    // ================= [영역 3] m1.cv1 =================
    // y2_buf가 이미 shortcut 값 자체이므로, 별도로 shortcut_1을
    // 만들 필요 없이 그냥 conv_in_s로 흘리기만 한다(feed_only).
    {
#pragma HLS DATAFLOW
        feed_only(y2_buf, conv_in_s);
        drain_to_array(bn_out_s, cv_mid_1);
    }

    // ================= [영역 4] m1.cv2 =================
    // shortcut은 y2_buf를 그대로 사용 (영역3에서 아무도 y2_buf를
    // 건드리지 않았으므로 여전히 유효한 값이다).
    {
#pragma HLS DATAFLOW
        feed_only(cv_mid_1, conv_in_s);
        drain_to_residual(bn_out_s, y2_buf, res_fx_s, res_x_s);
    }

    // ---- STEP10: residual_add 결과(y3) 도착 -> concat ----
STEP10: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        y3_out_s.write(res_out_s.read());
    }
}
