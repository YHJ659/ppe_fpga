#include "ap_int.h"
#include "hls_stream.h"

#define IN_CH   64
#define OUT_CH  64
#define IN_H    40
#define IN_W    40
#define K       3
#define PAD     1
#define N_SET   4     // m0.cv1, m0.cv2, m1.cv1, m1.cv2 — 프레임당 4회 재사용

// ============================================================
//  이번 변경: layer_id(PS가 s_axilite로 써주는 값) 폐기.
//
//  이유 — model.6 전체가 conv1x1(cv1)부터 bn_silu_128(cv2)까지
//  하나의 연속 AXI-Stream으로 직결돼 있다는 게 확인되면서, PS는
//  프레임당 딱 1번 트리거하고 그 뒤로는 개입할 지점이 없어짐.
//  즉 "conv3x3이 지금 몇 번째로 불렸는지"를 PS가 정확한 타이밍에
//  알려줄 방법 자체가 없어졌음.
//
//  해결: PS가 알려주는 대신 IP가 스스로 셉니다 (call_counter,
//  static이라 ap_start 될 때마다 값 유지). 4벌 가중치는 프레임
//  시작 전 한 번에 전부 받아 URAM(weight_bank, 파티션 없음)에
//  저장해두고, 매 호출마다 call_counter%4로 그중 하나를 골라
//  계산용 local_weight(기존 BRAM+파티션, 자원 변화 없음)로
//  복사합니다. 세트가 바뀔 때만 복사가 일어나므로 기존 캐싱
//  로직(last_loaded_id 방식)의 정신은 그대로 유지됩니다.
//
//  Vivado 쪽 요건: 이 IP의 s_axi_control에서 Auto Restart를
//  켜둬야 합니다 — PS가 매 호출마다 ap_start를 주지 않고도
//  스트림이 도착하는 대로 스스로 다시 시작해야 하기 때문입니다.
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
//  스테이지 1: 이전과 완전히 동일 (연산이 없는 부분, 영향 없음)
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
//  스테이지 2: 이전과 완전히 동일 (local_weight 형태/파티션도
//  변경 없음 — MAC 연산 자원(BRAM 144개)은 그대로 유지됨)
// ============================================================
static void compute_stage(
    hls::stream<window_row_t> &win_s,
    hls::stream<out_pix_t>    &out_s,
    ap_int<8> local_weight[OUT_CH][IN_CH][K][K]
) {
    ap_int<8> win[K][K][IN_CH];
#pragma HLS ARRAY_PARTITION variable=win complete dim=0

    ap_int<32> acc_partial[IC_PASS][OUT_CH];
#pragma HLS ARRAY_PARTITION variable=acc_partial complete dim=0

    int oh = 0, ow = 0;

    CS_MAIN: for (int t = 0; t < N_OUT * IC_PASS * OUT_CH; t++) {
#pragma HLS PIPELINE II=1

        int oc  = t % OUT_CH;
        int icp = (t / OUT_CH) % IC_PASS;

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
        acc_partial[icp][oc] = acc;

        if (icp == IC_PASS - 1 && oc == OUT_CH - 1) {
            out_pix_t oy;
            CS_PACK: for (int i = 0; i < OUT_CH; i++) {
#pragma HLS UNROLL
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

// ============================================================
//  가중치 관리: 4벌 창고(URAM, 파티션 없음) + 계산용 1벌(BRAM,
//  기존 파티션 유지) 두 단계로 분리.
//
//   1) bank_loaded == false 인 최초 1회에만: PS가 넘긴 weight[4][...]
//      전체를 weight_bank로 통째 복사 (프레임 시작 전, 시간 여유 있음)
//   2) 매 호출마다: call_counter로 이번이 몇 번째인지 스스로 판단,
//      필요한 세트가 이미 local_weight에 있으면 아무것도 안 함
//      (기존 last_loaded_id 캐싱과 동일한 정신)
// ============================================================
static void load_weights(
    ap_int<8> weight[N_SET][OUT_CH][IN_CH][K][K],
    ap_int<8> local_weight[OUT_CH][IN_CH][K][K]
) {
    static ap_int<8> weight_bank[N_SET][OUT_CH][IN_CH][K][K];
    // 파티션 없음 — concat/router 스킵버퍼와 같은 이유로 URAM에 최적
#pragma HLS BIND_STORAGE variable=weight_bank type=ram_1p impl=uram

    static bool bank_loaded = false;
    static int  loaded_set  = -1;
    static int  call_counter = 0;

    if (!bank_loaded) {
        LOAD_BANK: for (int k = 0; k < N_SET; k++) {
            for (int oc = 0; oc < OUT_CH; oc++) {
                for (int ic = 0; ic < IN_CH; ic++) {
#pragma HLS PIPELINE II=1
                    for (int kh = 0; kh < K; kh++) {
                        for (int kw = 0; kw < K; kw++) {
                            weight_bank[k][oc][ic][kh][kw] =
                                weight[k][oc][ic][kh][kw];
                        }
                    }
                }
            }
        }
        bank_loaded = true;
    }

    int my_set = call_counter % N_SET;
    call_counter++;

    if (loaded_set != my_set) {
        LOAD_LOCAL_OC: for (int oc = 0; oc < OUT_CH; oc++) {
            LOAD_LOCAL_IC: for (int ic = 0; ic < IN_CH; ic++) {
#pragma HLS PIPELINE II=1
                for (int kh = 0; kh < K; kh++) {
                    for (int kw = 0; kw < K; kw++) {
                        local_weight[oc][ic][kh][kw] =
                            weight_bank[my_set][oc][ic][kh][kw];
                    }
                }
            }
        }
        loaded_set = my_set;
    }
}

void conv3x3_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    ap_int<8> weight[N_SET][OUT_CH][IN_CH][K][K]   // PS가 프레임 시작 전 1회, 4벌 전체 로드
) {
#pragma HLS INTERFACE axis      port=in_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=weight
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s
#pragma HLS DATAFLOW

    static ap_int<8> local_weight[OUT_CH][IN_CH][K][K];
    // 기존과 완전히 동일 — 자원(BRAM 144개) 변화 없음
#pragma HLS ARRAY_PARTITION variable=local_weight cyclic factor=IC_UF dim=2
#pragma HLS ARRAY_PARTITION variable=local_weight complete            dim=3
#pragma HLS ARRAY_PARTITION variable=local_weight complete            dim=4
#pragma HLS BIND_STORAGE   variable=local_weight type=ram_1p impl=bram

    hls::stream<window_row_t> win_s;
#pragma HLS STREAM variable=win_s depth=12
#pragma HLS BIND_STORAGE variable=win_s type=fifo impl=lutram

    load_weights(weight, local_weight);
    produce_windows(in_s, win_s);
    compute_stage(win_s, out_s, local_weight);
}