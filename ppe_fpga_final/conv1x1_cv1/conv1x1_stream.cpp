#include "ap_int.h"
#include "hls_stream.h"

// model.6.cv1 (1x1 Conv) 기준
#define IN_CH   128
#define OUT_CH  128
#define H       40
#define W       40
#define N_PIX   (H * W)

// 앞단(split/concat 등)에서 오는 int8 픽셀
typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;   // 1024 bit
// bn_silu_128_stream의 입력 타입과 동일 (int32, 128채널)
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;  // 4096 bit

void conv1x1_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    ap_int<8> weight[OUT_CH][IN_CH]
) {
#pragma HLS INTERFACE axis port=in_s
#pragma HLS INTERFACE axis port=out_s
#pragma HLS INTERFACE bram port=weight
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // 공간 윈도우가 없으니 conv3x3의 라인버퍼/DATAFLOW 분리가 필요 없습니다.
    // 가중치는 한 번만 로드하면 되고, 여기엔 별도 스테이지로 겹칠 대상도
    // 없어서 DATAFLOW 없이 단순한 순차 코드로 충분합니다.
    static ap_int<8> local_weight[OUT_CH][IN_CH];
    // ic(입력채널) 전부를 한 사이클에 읽어야 하므로 complete.
    // oc(출력채널)는 매 사이클 하나씩만 접근하니 파티션 불필요.
#pragma HLS ARRAY_PARTITION variable=local_weight complete dim=2
#pragma HLS BIND_STORAGE   variable=local_weight type=ram_1p impl=lutram

    static bool wt_loaded = false;
    if (!wt_loaded) {
        LOAD_WT_OC: for (int oc = 0; oc < OUT_CH; oc++) {
#pragma HLS PIPELINE II=1
            for (int ic = 0; ic < IN_CH; ic++) {
                local_weight[oc][ic] = weight[oc][ic];
            }
        }
        wt_loaded = true;
    }

    // 더블 버퍼: bn_silu에서 검증된 패턴. 픽셀 홀짝으로 번갈아 써서
    // 다음 픽셀의 쓰기(oc==0)가 이전 픽셀의 마지막 읽기들과 겹쳐도
    // 충돌하지 않게 합니다 (II=1 유지의 핵심).
    ap_int<8> ibuf[2][IN_CH];
#pragma HLS ARRAY_PARTITION variable=ibuf complete dim=0

    ap_int<32> obuf[2][OUT_CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    // t = pixel * OUT_CH + oc
    MAIN: for (int t = 0; t < N_PIX * OUT_CH; t++) {
#pragma HLS PIPELINE II=1

        int oc  = t % OUT_CH;
        int par = (t / OUT_CH) & 1;

        // --- 새 픽셀 도착: 128채널을 통째로 언팩 ---
        if (oc == 0) {
            in_pix_t px = in_s.read();
            UNPACK: for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                ibuf[par][i] = px.ch[i];
            }
        }

        // --- 출력 채널 oc 하나: 128-way 내적 ---
        ap_int<32> acc = 0;
        MAC: for (int ic = 0; ic < IN_CH; ic++) {
#pragma HLS UNROLL
            acc += ibuf[par][ic] * local_weight[oc][ic];
        }
        obuf[par][oc] = acc;

        // --- 마지막 채널: 128개를 모아 한 픽셀로 내보냄 ---
        if (oc == OUT_CH - 1) {
            out_pix_t oy;
            PACK: for (int i = 0; i < OUT_CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
        }
    }
}