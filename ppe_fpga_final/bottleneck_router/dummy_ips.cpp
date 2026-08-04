#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

#define N_CALLS_CONV_BN 4   // conv3x3/bn_silu_64는 프레임당 4번 재사용됩니다
#define N_CALLS_RESIDUAL 2  // residual_add는 프레임당 2번 재사용됩니다

// 실제 conv3x3 대신: 채널마다 +1. (공간 혼합 없음 — 순서 검증만 목적)
// 실제 하드웨어에서 PS가 4번 따로 트리거하는 것을 흉내내, 바깥에
// N_CALLS_CONV_BN번 도는 루프를 추가했습니다. 한 번만 처리하고
// 끝내면 두 번째 재사용부터 아무도 안 읽어줘서 라우터가 멈춥니다.
void dummy_conv3x3(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s) {
	for (int call = 0; call < N_CALLS_CONV_BN; call++) {
        for (int p = 0; p < N_PIX; p++) {
        	pix8_t a = in_s.read(), b;
            for (int c = 0; c < CH; c++) b.ch[c] = a.ch[c] + 1;
            out_s.write(b);
        }
    }
}

// 실제 bn_silu_64 대신: 채널마다 +10.
void dummy_bn_silu(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s) {
    for (int call = 0; call < N_CALLS_CONV_BN; call++) {
        for (int p = 0; p < N_PIX; p++) {

        	pix8_t a = in_s.read(), b;
            for (int c = 0; c < CH; c++) b.ch[c] = a.ch[c] + 10;
            out_s.write(b);
        }
    }
}

// 실제 residual_add 대신: 진짜로 x+fx (구조가 동일해 그대로 사용 가능).
// 프레임당 2번(Bottleneck1, Bottleneck2) 재사용됩니다.
void dummy_residual_add(hls::stream<pix8_t> &x_s, hls::stream<pix8_t> &fx_s, hls::stream<pix8_t> &out_s) {
	for (int call = 0; call < N_CALLS_RESIDUAL; call++) {
        for (int p = 0; p < N_PIX; p++) {

        	pix8_t x = x_s.read(), fx = fx_s.read(), o;
            for (int c = 0; c < CH; c++) o.ch[c] = x.ch[c] + fx.ch[c];
            out_s.write(o);
        }
    }
}
