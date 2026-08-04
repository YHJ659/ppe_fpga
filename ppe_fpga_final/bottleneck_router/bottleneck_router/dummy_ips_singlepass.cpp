#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

void dummy_conv3x3(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s) {
    for (int p = 0; p < N_PIX; p++) {
        pix8_t a = in_s.read(), b;
        for (int c = 0; c < CH; c++) b.ch[c] = a.ch[c] + 1;
        out_s.write(b);
    }
}

void dummy_bn_silu(hls::stream<pix8_t> &in_s, hls::stream<pix8_t> &out_s) {
    for (int p = 0; p < N_PIX; p++) {
        pix8_t a = in_s.read(), b;
        for (int c = 0; c < CH; c++) b.ch[c] = a.ch[c] + 10;
        out_s.write(b);
    }
}

void dummy_residual_add(hls::stream<pix8_t> &x_s, hls::stream<pix8_t> &fx_s, hls::stream<pix8_t> &out_s) {
    for (int p = 0; p < N_PIX; p++) {
        pix8_t x = x_s.read(), fx = fx_s.read(), o;
        for (int c = 0; c < CH; c++) o.ch[c] = x.ch[c] + fx.ch[c];
        out_s.write(o);
    }
}