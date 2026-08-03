#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>
#include <cstdlib>

#define CH      64
#define OUT_CH  256
#define H       40
#define W       40
#define N_PIX   (H * W)

typedef struct { ap_int<8> ch[CH];     } pix_t;
typedef struct { ap_int<8> ch[OUT_CH]; } out_pix_t;

void concat_channel_stream(hls::stream<pix_t>&, hls::stream<pix_t>&,
                           hls::stream<pix_t>&, hls::stream<pix_t>&,
                           float, float, float, float, float,
                           hls::stream<out_pix_t>&);

static int       y0_raw[CH][H][W], y1_raw[CH][H][W], y2_raw[CH][H][W], y3_raw[CH][H][W];
static ap_int<8> y0_a[CH][H][W], y1_a[CH][H][W], y2_a[CH][H][W], y3_a[CH][H][W];
static ap_int<8> output_a[OUT_CH][H][W];
static int       golden_a[OUT_CH][H][W];

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
    // 로그 실측: y0~y3 전부 int32(4 B/elem)였습니다.
    if (!load_raw("y0.bin", &y0_raw[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("y1.bin", &y1_raw[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("y2.bin", &y2_raw[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("y3.bin", &y3_raw[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("golden_output.bin", &golden_a[0][0][0], OUT_CH*H*W, 4)) return 1;

    // int32 -> int8로 좁힙니다. 범위를 벗어나면 여기서 바로 걸러집니다.
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int v0 = y0_raw[c][h][w], v1 = y1_raw[c][h][w];
                int v2 = y2_raw[c][h][w], v3 = y3_raw[c][h][w];
                if (v0<-128||v0>127||v1<-128||v1>127||v2<-128||v2>127||v3<-128||v3>127) {
                    printf("[%d][%d][%d] out of int8 range: %d %d %d %d\n", c,h,w,v0,v1,v2,v3);
                    return 1;
                }
                y0_a[c][h][w] = (ap_int<8>)v0;
                y1_a[c][h][w] = (ap_int<8>)v1;
                y2_a[c][h][w] = (ap_int<8>)v2;
                y3_a[c][h][w] = (ap_int<8>)v3;
            }

    // ★ 실제 스케일 값으로 바꾸세요.
    float scale0 = 0.047591093018299016f, scale1 = 0.03178280357300766f, scale2 = 0.03628666945329801f, scale3 = 0.04050143309465543f, output_scale = 0.047591093018299016f;


    hls::stream<pix_t> y0_s("y0_s"), y1_s("y1_s"), y2_s("y2_s"), y3_s("y3_s");
    hls::stream<out_pix_t> out_s("out_s");

    // 네 스트림 모두 같은 픽셀 순서(raster)로 채웁니다.
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix_t p0, p1, p2, p3;
            for (int c = 0; c < CH; c++) {
                p0.ch[c] = y0_a[c][h][w];
                p1.ch[c] = y1_a[c][h][w];
                p2.ch[c] = y2_a[c][h][w];
                p3.ch[c] = y3_a[c][h][w];
            }
            y0_s.write(p0); y1_s.write(p1); y2_s.write(p2); y3_s.write(p3);
        }
    }

    concat_channel_stream(y0_s, y1_s, y2_s, y3_s,
                          scale0, scale1, scale2, scale3, output_scale, out_s);

    for (int h = 0; h < H; h++)
        for (int w = 0; w < W; w++) {
            out_pix_t oy = out_s.read();
            for (int c = 0; c < OUT_CH; c++) output_a[c][h][w] = oy.ch[c];
        }

    int errors = 0;
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int got = output_a[c][h][w];
                int exp = golden_a[c][h][w];
                if (abs(got - exp) > 1) {
                    if (errors < 10) printf("mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, got, exp);
                    errors++;
                }
            }

    if (!out_s.empty()) {
        printf("WARNING: output stream still has %d elements\n", (int)out_s.size());
        errors++;
    }

    printf(errors == 0 ? "TEST PASSED\n" : "TEST FAILED: %d mismatches\n", errors);
    return errors ? 1 : 0;
}
