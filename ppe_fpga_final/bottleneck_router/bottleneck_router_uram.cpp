#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// ============================================================
//  ★ 데드락 수정 v2 (2026-08): v1에서 놓쳤던 지점을 추가로 수정.
//
//  conv3x3은 프레임당 4번 불림: m0.cv1, m0.cv2, m1.cv1, m1.cv2.
//  라우터가 conv_in_s 에 값을 "feed"하는 지점도 4곳(STEP1,STEP2,
//  STEP6,STEP7) — 그런데 "feed하는 동안 그 호출 자신의 결과가
//  bn_out_s로 나오는데 아무도 안 받아준다"는 문제는 이 4곳 전부에
//  있었음. v1은 STEP1/STEP6(각 Bottleneck의 첫 conv)만 고쳤고,
//  STEP2/STEP7(각 Bottleneck의 둘째 conv)은 놓쳤었음 — 그래서
//  m0.cv1까지는 통과했지만 m0.cv2에서 다시 멈췄던 것.
//
//  이번엔 4곳 다 고침. STEP1/STEP6은 결과를 나중에 다시 conv에
//  넣어야 해서 버퍼(cv_out_buf)에 잠깐 저장. STEP2/STEP7은 결과를
//  바로 residual_add로 보내면 되므로, 버퍼 없이 받는 즉시
//  res_fx_s/res_x_s로 직접 전달(원래 STEP3_4/STEP8_9가 하던 일을
//  같은 자리에서 동시에 처리) — 그래서 새 버퍼 추가가 필요 없음.
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

    ap_int<8> y1_buf[CH][H][W];
    ap_int<8> y2_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=y1_buf cyclic factor=8 dim=3
#pragma HLS ARRAY_RESHAPE variable=y2_buf cyclic factor=8 dim=3
#pragma HLS BIND_STORAGE variable=y1_buf type=ram_1p impl=uram
#pragma HLS BIND_STORAGE variable=y2_buf type=ram_1p impl=uram

    // STEP1/STEP6 에서만 필요한 임시 버퍼 (m0.cv1/m1.cv1 결과를 잠깐
    // 담아뒀다가 m0.cv2/m1.cv2 입력으로 다시 씀). 두 Bottleneck에서
    // 순차적으로(동시에 아님) 재사용 — 버퍼 하나로 충분.
    ap_int<8> cv_out_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=cv_out_buf cyclic factor=8 dim=3
#pragma HLS BIND_STORAGE variable=cv_out_buf type=ram_1p impl=uram

    // ==================================================================
    // Bottleneck0 (m0.cv1 -> m0.cv2 -> residual_add)
    // ==================================================================
    {
        // ---- STEP1_MERGED: y1 -> conv_in_s (m0.cv1 입력), 동시에
        //      m0.cv1 결과(bn_out_s)를 몰래 받아 cv_out_buf에 저장 ----
        int recv_count = 0;
        int h_r = 0, w_r = 0;

        STEP1_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px = y1_s.read();
            conv_in_s.write(px);
            STEP1_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                y1_buf[c][h][w] = px.ch[c];
            }

            pix8_t bx;
            if (recv_count < N_PIX && bn_out_s.read_nb(bx)) {
                STEP1_DRAIN_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                    cv_out_buf[c][h_r][w_r] = bx.ch[c];
                }
                w_r++; if (w_r == W) { w_r = 0; h_r++; }
                recv_count++;
            }
        }
        STEP1_DRAIN_REST: while (recv_count < N_PIX) {
#pragma HLS PIPELINE II=1
            pix8_t bx = bn_out_s.read();
            STEP1_DRAIN_REST_C: for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
                cv_out_buf[c][h_r][w_r] = bx.ch[c];
            }
            w_r++; if (w_r == W) { w_r = 0; h_r++; }
            recv_count++;
        }

        // ---- STEP2_MERGED (★ 이번에 새로 고친 부분): cv_out_buf ->
        //      conv_in_s (m0.cv2 입력), 동시에 m0.cv2 결과(bn_out_s)를
        //      몰래 받아 곧바로 res_fx_s + res_x_s(y1_buf shortcut)로
        //      전달 — 버퍼링 없이 바로 내보냄 (원래 STEP3_4가 하던 일) ----
        int fwd_count = 0;
        int h_f = 0, w_f = 0;

        STEP2_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px;
            STEP2_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                px.ch[c] = cv_out_buf[c][h][w];
            }
            conv_in_s.write(px);

            pix8_t bx;
            if (fwd_count < N_PIX && bn_out_s.read_nb(bx)) {
                res_fx_s.write(bx);
                pix8_t xp;
                STEP2_FWD_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                    xp.ch[c] = y1_buf[c][h_f][w_f];
                }
                res_x_s.write(xp);
                w_f++; if (w_f == W) { w_f = 0; h_f++; }
                fwd_count++;
            }
        }
        STEP2_DRAIN_REST: while (fwd_count < N_PIX) {
#pragma HLS PIPELINE II=1
            pix8_t bx = bn_out_s.read();
            res_fx_s.write(bx);
            pix8_t xp;
            STEP2_DRAIN_REST_C: for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
                xp.ch[c] = y1_buf[c][h_f][w_f];
            }
            res_x_s.write(xp);
            w_f++; if (w_f == W) { w_f = 0; h_f++; }
            fwd_count++;
        }
    }

    // ---- STEP5: residual_add 결과(y2) 도착 -> concat + y2_buf 저장 ----
    // (변경 없음 — conv_in_s에 아무것도 안 써서 데드락 위험 없었음)
    STEP5: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = res_out_s.read();
        y2_out_s.write(px);
        STEP5_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y2_buf[c][h][w] = px.ch[c];
        }
    }

    // ==================================================================
    // Bottleneck1 (m1.cv1 -> m1.cv2 -> residual_add) — 위와 완전히 동일한 패턴
    // ==================================================================
    {
        // ---- STEP6_MERGED: y2_buf -> conv_in_s (m1.cv1 입력), 동시에
        //      m1.cv1 결과를 cv_out_buf에 저장 (STEP1 다 쓴 뒤라 재사용 안전) ----
        int recv_count = 0;
        int h_r = 0, w_r = 0;

        STEP6_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px;
            STEP6_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                px.ch[c] = y2_buf[c][h][w];
            }
            conv_in_s.write(px);

            pix8_t bx;
            if (recv_count < N_PIX && bn_out_s.read_nb(bx)) {
                STEP6_DRAIN_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                    cv_out_buf[c][h_r][w_r] = bx.ch[c];
                }
                w_r++; if (w_r == W) { w_r = 0; h_r++; }
                recv_count++;
            }
        }
        STEP6_DRAIN_REST: while (recv_count < N_PIX) {
#pragma HLS PIPELINE II=1
            pix8_t bx = bn_out_s.read();
            STEP6_DRAIN_REST_C: for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
                cv_out_buf[c][h_r][w_r] = bx.ch[c];
            }
            w_r++; if (w_r == W) { w_r = 0; h_r++; }
            recv_count++;
        }

        // ---- STEP7_MERGED (★ 새로 고친 부분): cv_out_buf -> conv_in_s
        //      (m1.cv2 입력), 동시에 m1.cv2 결과를 res_fx_s+res_x_s(y2_buf)로 ----
        int fwd_count = 0;
        int h_f = 0, w_f = 0;

        STEP7_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px;
            STEP7_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                px.ch[c] = cv_out_buf[c][h][w];
            }
            conv_in_s.write(px);

            pix8_t bx;
            if (fwd_count < N_PIX && bn_out_s.read_nb(bx)) {
                res_fx_s.write(bx);
                pix8_t xp;
                STEP7_FWD_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                    xp.ch[c] = y2_buf[c][h_f][w_f];
                }
                res_x_s.write(xp);
                w_f++; if (w_f == W) { w_f = 0; h_f++; }
                fwd_count++;
            }
        }
        STEP7_DRAIN_REST: while (fwd_count < N_PIX) {
#pragma HLS PIPELINE II=1
            pix8_t bx = bn_out_s.read();
            res_fx_s.write(bx);
            pix8_t xp;
            STEP7_DRAIN_REST_C: for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
                xp.ch[c] = y2_buf[c][h_f][w_f];
            }
            res_x_s.write(xp);
            w_f++; if (w_f == W) { w_f = 0; h_f++; }
            fwd_count++;
        }
    }

    // ---- STEP10: residual_add 결과(y3) 도착 -> concat (버퍼링 불필요) ----
    STEP10: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        y3_out_s.write(res_out_s.read());
    }
}
