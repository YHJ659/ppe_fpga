#include "ap_int.h"
#include "hls_stream.h"

#define IN_CH   128
#define OUT_CH  64      // 반으로 나뉨
#define H       40
#define W       40
#define N_PIX   (H * W)

typedef struct { ap_int<8> ch[IN_CH];  } in_pix_t;   // 1024 bit
typedef struct { ap_int<8> ch[OUT_CH]; } out_pix_t;  // 512 bit — bn_silu_64 계열과 동일 폭

// ============================================================
//  y1(뒤쪽 절반)은 두 곳에 필요합니다:
//   1) bottleneck_router.y1_s — Bottleneck1의 conv1 입력이자
//      residual_add의 shortcut (라우터 내부에서 프레임버퍼링됨)
//   2) concat.y1_s — 가공되지 않은 원본 그대로
//  라우터는 concat과 직접 연결되어 있지 않으므로, 이 두 경로는
//  split 단계에서 미리 갈라놔야 합니다. y0는 처음부터 concat
//  하나로만 가니 그대로 둡니다.
// ============================================================
void split_channel_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &y0_s,        // 앞쪽 절반 (0~63채널) -> concat
    hls::stream<out_pix_t> &y1_router_s, // 뒤쪽 절반 -> bottleneck_router
    hls::stream<out_pix_t> &y1_concat_s  // 뒤쪽 절반 -> concat (동일한 값)
) {
#pragma HLS INTERFACE axis port=in_s
#pragma HLS INTERFACE axis port=y0_s
#pragma HLS INTERFACE axis port=y1_router_s
#pragma HLS INTERFACE axis port=y1_concat_s
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=y0_s
#pragma HLS AGGREGATE compact=bit variable=y1_router_s
#pragma HLS AGGREGATE compact=bit variable=y1_concat_s

    // 계산이 없고 픽셀 간에 유지할 상태도 없으니, 이전 IP들의
    // 더블 버퍼링/단일 카운터 병합 자체가 필요 없습니다.
    // 픽셀 하나 받아서 반으로 나눈 뒤, y1만 두 스트림에 똑같이
    // 씁니다(복제). 계산이 없는 IP라 자원 부담이 거의 없습니다.
    MAIN: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1

        in_pix_t px = in_s.read();

        out_pix_t o0, o1;
        SPLIT: for (int c = 0; c < OUT_CH; c++) {
#pragma HLS UNROLL
            o0.ch[c] = px.ch[c];
            o1.ch[c] = px.ch[c + OUT_CH];
        }

        y0_s.write(o0);
        y1_router_s.write(o1);
        y1_concat_s.write(o1);   // 같은 값을 한 번 더 — 복제
    }
}