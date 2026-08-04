#include "ap_int.h"
#include "hls_stream.h"

#define CH    128
#define H     40
#define W     40
#define N_PIX (H * W)

// conv1x1의 출력 / bn_silu_128의 입력과 같은 타입 (int32, 128채널)
typedef struct { ap_int<32> ch[CH]; } pix128_32_t;
// bn_silu_128의 출력과 같은 타입 (int8, 128채널)
typedef struct { ap_int<8>  ch[CH]; } pix128_8_t;

// ============================================================
//  bn_silu_128은 프레임당 2번 재사용됩니다:
//   1번째: conv1x1(cv1) → bn_silu_128 → split
//   2번째: conv1x1(cv2) → bn_silu_128 → DMA(쓰기)
//
//  bottleneck_router와 달리 루프백이나 나중에 다시 꺼내 쓸
//  shortcut 값이 없습니다 — 그냥 "이번엔 어느 쪽과 연결할지"만
//  순서대로 바꿔주면 끝입니다. 그래서 프레임 버퍼가 전혀 없고,
//  4단계 순수 전달(pass-through)로 충분합니다.
// ============================================================
void bn128_router(
    hls::stream<pix128_32_t> &cv1_out_s,   // conv1x1(cv1)의 출력
    hls::stream<pix128_32_t> &cv2_out_s,   // conv1x1(cv2)의 출력
    hls::stream<pix128_8_t>  &bn_out_s,    // bn_silu_128.out_s (2번 도착)

    hls::stream<pix128_32_t> &bn_in_s,     // -> bn_silu_128.in_s
    hls::stream<pix128_8_t>  &split_in_s,  // -> split.in_s
    hls::stream<pix128_8_t>  &final_out_s  // -> DMA(쓰기)
) {
#pragma HLS INTERFACE axis port=cv1_out_s
#pragma HLS INTERFACE axis port=cv2_out_s
#pragma HLS INTERFACE axis port=bn_out_s
#pragma HLS INTERFACE axis port=bn_in_s
#pragma HLS INTERFACE axis port=split_in_s
#pragma HLS INTERFACE axis port=final_out_s
#pragma HLS INTERFACE s_axilite port=return

    // ---- 1) cv1의 출력을 bn_silu_128로 전달 ----
    STEP1: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        bn_in_s.write(cv1_out_s.read());
    }

    // ---- 2) bn_silu_128의 1번째 결과를 split으로 전달 ----
    STEP2: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        split_in_s.write(bn_out_s.read());
    }

    // ---- 3) cv2의 출력을 bn_silu_128로 전달 ----
    STEP3: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        bn_in_s.write(cv2_out_s.read());
    }

    // ---- 4) bn_silu_128의 2번째 결과를 최종 출력(DMA)으로 전달 ----
    STEP4: for (int p = 0; p < N_PIX; p++) {
#pragma HLS PIPELINE II=1
        final_out_s.write(bn_out_s.read());
    }
}