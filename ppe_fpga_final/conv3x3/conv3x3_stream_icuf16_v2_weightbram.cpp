#include "ap_int.h"
#include "hls_stream.h"

#define IN_CH   64
#define OUT_CH  64
#define IN_H    40
#define IN_W    40
#define K       3
#define PAD     1

// ============================================================
//  IC_UF=16 재시도. 지난번 실패 원인은 acc_buf[oc]를 icp마다
//  "읽고 다시 쓰는" 재귀였습니다 — MAC 파이프라인 깊이(149)가
//  재귀 거리(64)보다 길어서 II가 144까지 밀렸습니다.
//
//  이번엔 4개 icp 패스의 부분합을 서로 다른 슬롯에 "쓰기만"
//  합니다. 같은 자리를 다시 읽는 일 자체가 없으니 재귀가
//  구조적으로 사라집니다. 대신 픽셀이 끝나는 시점에 4개를
//  한 번 더해주는 단계가 추가되는데, 이건 완전 언롤하면
//  사실상 공짜입니다.
// ============================================================
#define IC_UF   16
#define IC_PASS (IN_CH / IC_UF)   // 4

#define N_IN    (IN_H * IN_W)
#define LAG     (IN_W + 1)
#define N_STEP  (N_IN + LAG)
#define N_OUT   (IN_H * IN_W)

typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;
typedef struct { ap_int<8> v[K][IN_CH]; } window_row_t;

// ============================================================
//  스테이지 1: 이전과 동일 (연산이 없는 부분이라 영향받지 않음)
//  linebuf는 작아서(40,960bit) LUTRAM 전환이 거의 공짜였으므로
//  그대로 유지합니다 (되돌릴 실익 없음).
// ============================================================
static void produce_windows(
    hls::stream<in_pix_t>      &in_s,
    hls::stream<window_row_t>  &win_s
) {
    ap_int<8> linebuf[2][IN_W][IN_CH];
#pragma HLS ARRAY_PARTITION variable=linebuf complete dim=1
#pragma HLS ARRAY_PARTITION variable=linebuf complete dim=3
#pragma HLS BIND_STORAGE   variable=linebuf type=ram_1p impl=lutram

    ap_int<8> window[K][K][IN_CH];
#pragma HLS ARRAY_PARTITION variable=window complete dim=0

    ap_int<8> pxv[IN_CH];
#pragma HLS ARRAY_PARTITION variable=pxv complete dim=1

    int col = 0;

    PW_MAIN: for (int t = 0; t < N_STEP; t++) {
#pragma HLS PIPELINE II=1

        if (t < N_IN) {
            in_pix_t px = in_s.read();
            PW_UNPACK: for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                pxv[i] = px.ch[i];
            }
        } else {
            PW_ZERO: for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                pxv[i] = 0;
            }
        }

        PW_SHIFT: for (int kh = 0; kh < K; kh++) {
#pragma HLS UNROLL
            for (int kw = 0; kw < K - 1; kw++) {
#pragma HLS UNROLL
                for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                    window[kh][kw][i] = window[kh][kw + 1][i];
                }
            }
        }

        PW_FILL: for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
            ap_int<8> a = linebuf[0][col][i];
            ap_int<8> b = linebuf[1][col][i];
            window[0][K-1][i] = a;
            window[1][K-1][i] = b;
            window[2][K-1][i] = pxv[i];
            linebuf[0][col][i] = b;
            linebuf[1][col][i] = pxv[i];
        }

        if (t >= LAG) {
            PW_PACK_ROW: for (int kh = 0; kh < K; kh++) {
                window_row_t r;
                for (int kw = 0; kw < K; kw++) {
                    for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                        r.v[kw][i] = window[kh][kw][i];
                    }
                }
                win_s.write(r);
            }
        }

        col++;
        if (col == IN_W) col = 0;
    }
}

// ============================================================
//  스테이지 2: acc_partial[IC_PASS][OUT_CH] — icp마다 독립된
//  슬롯에만 씁니다. 이전 값을 읽지 않으니 read-after-write
//  자체가 없어서 II=1이 걸릴 조건이 원천적으로 갖춰집니다.
// ============================================================
static void compute_stage(
    hls::stream<window_row_t> &win_s,
    hls::stream<out_pix_t>    &out_s,
    ap_int<8> local_weight[OUT_CH][IN_CH][K][K]
) {
    ap_int<8> win[K][K][IN_CH];
#pragma HLS ARRAY_PARTITION variable=win complete dim=0

    // IC_PASS(4) x OUT_CH(64) = 256개. 각 (icp,oc)가 자기 슬롯에만
    // 씁니다 — 재귀 없음.
    ap_int<32> acc_partial[IC_PASS][OUT_CH];
#pragma HLS ARRAY_PARTITION variable=acc_partial complete dim=0

    int oh = 0, ow = 0;

    CS_MAIN: for (int t = 0; t < N_OUT * IC_PASS * OUT_CH; t++) {
#pragma HLS PIPELINE II=1

        int oc  = t % OUT_CH;
        int icp = (t / OUT_CH) % IC_PASS;

        // --- 새 윈도우 시작(icp==0, oc==0): 3줄 읽어 재조립 ---
        if (icp == 0 && oc == 0) {
            window_row_t r0 = win_s.read();
            window_row_t r1 = win_s.read();
            window_row_t r2 = win_s.read();
            CS_RECV0: for (int kw = 0; kw < K; kw++) {
#pragma HLS UNROLL
                for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                    win[0][kw][i] = r0.v[kw][i];
                    win[1][kw][i] = r1.v[kw][i];
                    win[2][kw][i] = r2.v[kw][i];
                }
            }
        }

        // --- icp 패스 하나: 16-way MAC, 자기 슬롯에만 씀 (읽기 없음) ---
        ap_int<32> acc = 0;
#pragma HLS BIND_OP variable=acc op=add impl=dsp
        CS_MAC: for (int ici = 0; ici < IC_UF; ici++) {
#pragma HLS UNROLL
            for (int kh = 0; kh < K; kh++) {
                for (int kw = 0; kw < K; kw++) {
                    int ic = icp * IC_UF + ici;
                    int ih = oh + kh - PAD;
                    int iw = ow + kw - PAD;
                    if (ih >= 0 && ih < IN_H && iw >= 0 && iw < IN_W) {
                        acc += win[kh][kw][ic]
                             * local_weight[oc][ic][kh][kw];
                    }
                }
            }
        }
        acc_partial[icp][oc] = acc;   // 쓰기만. 다음에 이 자리를 다시
                                       // 쓰는 건 256번 뒤라 안전합니다.

        // --- 마지막 icp 패스의 마지막 oc: 4개 부분합을 합쳐서 내보냄 ---
        if (icp == IC_PASS - 1 && oc == OUT_CH - 1) {
            out_pix_t oy;
            CS_PACK: for (int i = 0; i < OUT_CH; i++) {
#pragma HLS UNROLL
                // 4개 부분합을 한 번에 더합니다. 지금 DSP는 여유가 넉넉하고
                // (KV260 1,248개 중 현재 합계 406개 사용) LUT가 빠듯하므로,
                // 이 덧셈도 LUT 대신 DSP에 배정합니다.
                ap_int<32> sum;
#pragma HLS BIND_OP variable=sum op=add impl=dsp
                sum = acc_partial[0][i] + acc_partial[1][i]
                    + acc_partial[2][i] + acc_partial[3][i];
                oy.ch[i] = sum;
            }
            out_s.write(oy);

            ow++;
            if (ow == IN_W) { ow = 0; oh++; }
        }
    }
}

static void load_weights(
    ap_int<8> weight[OUT_CH][IN_CH][K][K],
    ap_int<8> local_weight[OUT_CH][IN_CH][K][K],
    int layer_id
) {
    static int last_loaded_id = -1;
    if (last_loaded_id != layer_id) {
        LOAD_WT_OC: for (int oc = 0; oc < OUT_CH; oc++) {
            LOAD_WT_IC: for (int ic = 0; ic < IN_CH; ic++) {
#pragma HLS PIPELINE II=1
                for (int kh = 0; kh < K; kh++) {
                    for (int kw = 0; kw < K; kw++) {
                        local_weight[oc][ic][kh][kw] = weight[oc][ic][kh][kw];
                    }
                }
            }
        }
        last_loaded_id = layer_id;
    }
}

void conv3x3_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    ap_int<8> weight[OUT_CH][IN_CH][K][K],
    int layer_id
) {
#pragma HLS INTERFACE axis      port=in_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=weight
#pragma HLS INTERFACE s_axilite port=layer_id
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s
#pragma HLS DATAFLOW

    static ap_int<8> local_weight[OUT_CH][IN_CH][K][K];
#pragma HLS ARRAY_PARTITION variable=local_weight cyclic factor=IC_UF dim=2
#pragma HLS ARRAY_PARTITION variable=local_weight complete            dim=3
#pragma HLS ARRAY_PARTITION variable=local_weight complete            dim=4
    // ★ 이번 실험: LUTRAM → BRAM. 294,912bit짜리 가중치 캐시라
    // win_s(18,432bit)와 달리 절감폭이 클 가능성이 있습니다.
    // BRAM은 현재 150/288 사용 중이라 여유가 충분합니다.
#pragma HLS BIND_STORAGE   variable=local_weight type=ram_1p impl=bram

    hls::stream<window_row_t> win_s;
#pragma HLS STREAM variable=win_s depth=12
#pragma HLS BIND_STORAGE variable=win_s type=fifo impl=lutram

    load_weights(weight, local_weight, layer_id);
    produce_windows(in_s, win_s);
    compute_stage(win_s, out_s, local_weight);
}