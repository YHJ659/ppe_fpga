#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define IN_CH   128
#define OUT_CH  64
#define H       40
#define W       40
#define N_PIX   (H * W)

typedef struct { ap_int<8> ch[IN_CH];  } in_pix_t;
typedef struct { ap_int<8> ch[OUT_CH]; } out_pix_t;

void split_channel_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &y0_s,
    hls::stream<out_pix_t> &y1_router_s,
    hls::stream<out_pix_t> &y1_concat_s
);

static ap_int<8> input_a  [IN_CH][H][W];
static ap_int<8> y0_a     [OUT_CH][H][W];
static ap_int<8> y1r_a    [OUT_CH][H][W];
static ap_int<8> y1c_a    [OUT_CH][H][W];
static ap_int<8> golden0_a[OUT_CH][H][W];
static ap_int<8> golden1_a[OUT_CH][H][W];

static bool load_raw(const char *path, void *dst, int n, int elem_bytes) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return false; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); rewind(f);
    printf("%s: %ld bytes / %d elems = %ld B/elem\n", path, sz, n, sz / n);
    size_t got = fread(dst, elem_bytes, n, f);
    fclose(f);
    return got == (size_t)n;
}

int main() {
    // ★ 파일 이름/포맷은 기존 split 테스트벤치(dtype 확인됨: int32)와 동일하게.
    static int input_raw[IN_CH][H][W];
    static int g0_raw[OUT_CH][H][W];
    static int g1_raw[OUT_CH][H][W];

    if (!load_raw("input.bin",   &input_raw[0][0][0], IN_CH*H*W,  4)) return 1;
    if (!load_raw("golden_y0.bin", &g0_raw[0][0][0],  OUT_CH*H*W, 4)) return 1;
    if (!load_raw("golden_y1.bin", &g1_raw[0][0][0],  OUT_CH*H*W, 4)) return 1;

    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int v = input_raw[c][h][w];
                if (v < -128 || v > 127) { printf("input 범위 밖: %d\n", v); return 1; }
                input_a[c][h][w] = (ap_int<8>)v;
            }
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                golden0_a[c][h][w] = (ap_int<8>)g0_raw[c][h][w];
                golden1_a[c][h][w] = (ap_int<8>)g1_raw[c][h][w];
            }

    hls::stream<in_pix_t>  in_s("in_s");
    hls::stream<out_pix_t> y0_s("y0_s"), y1_router_s("y1_router_s"), y1_concat_s("y1_concat_s");

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            in_pix_t px;
            for (int c = 0; c < IN_CH; c++) px.ch[c] = input_a[c][h][w];
            in_s.write(px);
        }
    }

    split_channel_stream(in_s, y0_s, y1_router_s, y1_concat_s);

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            out_pix_t o0 = y0_s.read();
            out_pix_t o1r = y1_router_s.read();
            out_pix_t o1c = y1_concat_s.read();
            for (int c = 0; c < OUT_CH; c++) {
                y0_a[c][h][w]  = o0.ch[c];
                y1r_a[c][h][w] = o1r.ch[c];
                y1c_a[c][h][w] = o1c.ch[c];
            }
        }
    }

    int errors = 0;
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                if (y0_a[c][h][w] != golden0_a[c][h][w]) {
                    if (errors < 10) printf("y0 mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y0_a[c][h][w], (int)golden0_a[c][h][w]);
                    errors++;
                }
                if (y1r_a[c][h][w] != golden1_a[c][h][w]) {
                    if (errors < 10) printf("y1_router mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y1r_a[c][h][w], (int)golden1_a[c][h][w]);
                    errors++;
                }
                if (y1c_a[c][h][w] != golden1_a[c][h][w]) {
                    if (errors < 10) printf("y1_concat mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, (int)y1c_a[c][h][w], (int)golden1_a[c][h][w]);
                    errors++;
                }
                if (y1r_a[c][h][w] != y1c_a[c][h][w]) {
                    if (errors < 10) printf("y1_router != y1_concat at [%d][%d][%d]\n", c, h, w);
                    errors++;
                }
            }

    if (!y0_s.empty() || !y1_router_s.empty() || !y1_concat_s.empty()) {
        printf("WARNING: output streams not empty\n");
        errors++;
    }

    printf(errors == 0 ? "TEST PASSED\n" : "TEST FAILED: %d mismatches\n", errors);
    return errors ? 1 : 0;
}