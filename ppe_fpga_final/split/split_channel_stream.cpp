#include "ap_int.h"
#include "hls_stream.h"

#define IN_CH   128
#define OUT_CH  64      // 반으로 나뉨
#define H       40
#define W       40
#define N_PIX   (H * W)

typedef struct { ap_int<8> ch[IN_CH];  } in_pix_t;   // 1024 bit
typedef struct { ap_int<8> ch[OUT_CH]; } out_pix_t;  // 512 bit — bn_silu_64 계열과 동일 폭

void split_channel_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &y0_s,   // 앞쪽 절반 (0~63채널)
    hls::stream<out_pix_t> &y1_s    // 뒤쪽 절반 (64~127채널)
) {
#pragma HLS INTERFACE axis port=in_s
#pragma HLS INTERFACE axis port=y0_s
#pragma HLS INTERFACE axis port=y1_s
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=y0_s
#pragma HLS AGGREGATE compact=bit variable=y1_s

    // 계산이 없고 픽셀 간에 유지할 상태도 없으니, 이전 IP들의
    // 더블 버퍼링/단일 카운터 병합 자체가 필요 없습니다.
    // 픽셀 하나 받아서 그대로 반으로 나눠 두 번 쓰면 끝입니다.
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
        y1_s.write(o1);
    }
}