#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// ============================================================
//  ★ 데드락 수정 (2026-08): 실제 보드 테스트에서 발견됨.
//
//  문제: STEP1(y1_s -> conv_in_s, 1600번 씀)이 다 끝나야 STEP2가
//  bn_out_s를 읽기 시작했음. 그런데 conv3x3+bn_silu_64가 라우터
//  바깥에서 직결(stream)돼 있어, STEP1이 y1을 쓰는 동안 이미
//  conv3x3의 결과가 bn_silu_64를 거쳐 bn_out_s로 나오기 시작함.
//  bn_out_s를 아무도 안 비우니 그 FIFO가 가득 차서 bn_silu_64가
//  멈추고, 그러면 conv3x3도 막혀서 conv_in_s에 못 쓰게 되고,
//  결국 STEP1 자신도 못 끝나는 순환 대기(데드락)였음.
//  STEP6/STEP7(Bottleneck1, m1.cv1->m1.cv2)에도 동일한 구조라
//  같은 문제가 있었음 — 같이 수정.
//
//  해결: conv_in_s에 쓰는 순서 자체(y1 1600개 다음 cv1_out 1600개)
//  는 바꿀 수 없음(conv3x3의 call_counter가 정확히 이 순서를
//  기대함). 대신 "쓰는 동시에, 나오는 걸 논블로킹으로 몰래 받아
//  버퍼에 저장"하는 방식으로 바꿈 (hls::stream::read_nb 사용).
//  y1_buf와 똑같은 URAM 기법으로 cv_out_buf를 하나 추가.
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

    // ★ 신규: STEP1/STEP6 동안 몰래 받아둘 cv1_out(m0.cv1, m1.cv1의 결과) 버퍼.
    // y1_buf/y2_buf와 같은 크기·같은 기법(URAM+reshape8) — 자원 부담 동일 패턴.
    ap_int<8> cv_out_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=cv_out_buf cyclic factor=8 dim=3
#pragma HLS BIND_STORAGE variable=cv_out_buf type=ram_1p impl=uram

    ap_int<8> pxv[CH];

    // ------------------------------------------------------------------
    // STEP1+2 병합 (Bottleneck0, m0.cv1 -> m0.cv2)
    // ------------------------------------------------------------------
    {
        int recv_count = 0;   // bn_out_s 에서 지금까지 몰래 받은 개수
        int h_r = 0, w_r = 0; // cv_out_buf 에 쓸 다음 위치

        // ---- y1 을 conv_in_s 에 쓰는 동안, bn_out_s 를 논블로킹으로 계속 확인 ----
        STEP1_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px = y1_s.read();
            conv_in_s.write(px);
            STEP1_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                y1_buf[c][h][w] = px.ch[c];
            }

            // 이번 사이클에 conv3x3->bn_silu_64 결과가 나왔으면 즉시 받아서 버퍼링.
            // 없으면(아직 파이프라인이 덜 찼으면) 그냥 넘어감 — 절대 안 막힘.
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

        // ---- STEP1 다 썼는데 아직 못 받은 나머지(파이프라인 지연분)는 블로킹으로 마무리 ----
        STEP1_DRAIN_REST: while (recv_count < N_PIX) {
#pragma HLS PIPELINE II=1
            pix8_t bx = bn_out_s.read();   // 이제는 conv3x3 입력이 안 밀리니 안전하게 블로킹
            STEP1_DRAIN_REST_C: for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
                cv_out_buf[c][h_r][w_r] = bx.ch[c];
            }
            w_r++; if (w_r == W) { w_r = 0; h_r++; }
            recv_count++;
        }

        // ---- 이제 cv_out_buf(=cv1_out, m0.cv2 입력)를 conv_in_s 로 흘려보냄 ----
        STEP2_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px;
            STEP2_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                px.ch[c] = cv_out_buf[c][h][w];
            }
            conv_in_s.write(px);
        }
    }

    // ---- STEP3_4: m0.cv2 결과(bn_out_s) + y1_buf(shortcut) -> residual_add ----
    // (기존과 동일 — 여긴 conv_in_s에 아무것도 안 쓰므로 데드락 위험 없었음)
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

    // ---- STEP5: residual_add 결과(y2) 도착 -> concat + y2_buf 저장 ----
    STEP5: for (int p = 0; p < N_PIX; p++) {
        int h = p / W, w = p % W;
        pix8_t px = res_out_s.read();
        y2_out_s.write(px);
        STEP5_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
            y2_buf[c][h][w] = px.ch[c];
        }
    }

    // ------------------------------------------------------------------
    // STEP6+7 병합 (Bottleneck1, m1.cv1 -> m1.cv2) — STEP1+2와 동일한 이유로 병합
    // ------------------------------------------------------------------
    {
        int recv_count = 0;
        int h_r = 0, w_r = 0;

        // ---- y2_buf(on-chip) 를 conv_in_s 에 쓰는 동안, bn_out_s 를 논블로킹 확인 ----
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

        STEP7_MERGED: for (int p = 0; p < N_PIX; p++) {
            int h = p / W, w = p % W;
            pix8_t px;
            STEP7_C: for (int c = 0; c < CH; c++) {
#pragma HLS PIPELINE II=1
                px.ch[c] = cv_out_buf[c][h][w];
            }
            conv_in_s.write(px);
        }
    }

    // ---- STEP8_9: m1.cv2 결과(bn_out_s) + y2_buf(shortcut) -> residual_add ----
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

    // ---- STEP10: residual_add 결과(y3) 도착 -> concat (버퍼링 불필요) ----
    STEP10: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        y3_out_s.write(res_out_s.read());
    }
}
