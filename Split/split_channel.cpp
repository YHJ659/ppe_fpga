#include "ap_int.h"

#define IN_CH   128
#define OUT_CH  64      // 반으로 나뉨
#define H       40
#define W       40

void split_channel(
    ap_int<8> input[IN_CH][H][W],
    ap_int<8> y0[OUT_CH][H][W],   // 앞쪽 절반 (0~63채널)
    ap_int<8> y1[OUT_CH][H][W]    // 뒤쪽 절반 (64~127채널)
) {
#pragma HLS INTERFACE bram port=input
#pragma HLS INTERFACE bram port=y0
#pragma HLS INTERFACE bram port=y1

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
#pragma HLS PIPELINE II=1
            for (int c = 0; c < OUT_CH; c++) {
                y0[c][h][w] = input[c][h][w];
                y1[c][h][w] = input[c + OUT_CH][h][w];
            }
        }
    }
}