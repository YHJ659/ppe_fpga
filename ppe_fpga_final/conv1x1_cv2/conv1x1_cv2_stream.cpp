#include "ap_int.h"
#include "hls_stream.h"

// model.6.cv2 (1x1 Conv, concat 직후) 기준. cv1(128->128)과는
// 입력 채널 수 자체가 달라 배열 크기가 다르므로 별도 IP입니다.
// 프레임당 1회만 호출되니 layer_id/캐싱 전환 로직은 필요 없습니다
// (cv1의 layer_id 작업이 애초에 불필요했던 것과 같은 이유).
#define IN_CH   256
#define OUT_CH  128
#define H       40
#define W       40
#define N_PIX   (H * W)

// concat_channel_stream의 출력(256채널 int8)과 그대로 이어집니다.
typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;   // 2048 bit
// bn_silu_128_stream의 입력 타입과 동일 (int32, 128채널)
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;  // 4096 bit

void conv1x1_cv2_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    ap_int<8> weight[OUT_CH][IN_CH]
) {
#pragma HLS INTERFACE axis port=in_s
#pragma HLS INTERFACE axis port=out_s
#pragma HLS INTERFACE bram port=weight
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // cv1과 동일하게 DATAFLOW 없는 단순 구조 (공간 윈도우가 없어서
    // 겹쳐 돌릴 별도 스테이지가 필요 없습니다).
    static ap_int<8> local_weight[OUT_CH][IN_CH];
#pragma HLS ARRAY_PARTITION variable=local_weight complete dim=2
#pragma HLS BIND_STORAGE   variable=local_weight type=ram_1p impl=lutram

    // 프레임당 1회 호출이라 매번 같은 가중치입니다. 한 번만 로드하면
    // 충분하고, cv1처럼 여기서도 layer_id 전환은 불필요합니다.
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

    // 더블 버퍼: bn_silu/conv1x1(cv1)에서 검증된 패턴 그대로.
    ap_int<8> ibuf[2][IN_CH];
#pragma HLS ARRAY_PARTITION variable=ibuf complete dim=0

    ap_int<32> obuf[2][OUT_CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    // t = pixel * OUT_CH + oc
    MAIN: for (int t = 0; t < N_PIX * OUT_CH; t++) {
#pragma HLS PIPELINE II=1

        int oc  = t % OUT_CH;
        int par = (t / OUT_CH) & 1;

        // --- 새 픽셀 도착: 256채널을 통째로 언팩 ---
        if (oc == 0) {
            in_pix_t px = in_s.read();
            UNPACK: for (int i = 0; i < IN_CH; i++) {
#pragma HLS UNROLL
                ibuf[par][i] = px.ch[i];
            }
        }

        // --- 출력 채널 oc 하나: 256-way 내적 (cv1의 128-way보다 큼) ---
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