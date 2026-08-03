#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>
#include <cstdlib>

#define CH   64
#define H    40
#define W    40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix_t;

void residual_add_stream(hls::stream<pix_t>&, hls::stream<pix_t>&, hls::stream<pix_t>&,
                         float, float, float);

static int       x_raw    [CH][H][W];   // 파일 실측: int32였음 (4 B/elem)
static int       fx_raw   [CH][H][W];
static ap_int<8> x_a     [CH][H][W];
static ap_int<8> fx_a    [CH][H][W];
static ap_int<8> output_a[CH][H][W];
static int       golden_a[CH][H][W];

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
    // ★ 파일 이름은 기존 residual_add 테스트벤치의 실제 이름으로 바꾸세요.
    if (!load_raw("x_input.bin",      &x_raw[0][0][0],    CH*H*W, 4)) return 1;
    if (!load_raw("fx_input.bin",     &fx_raw[0][0][0],   CH*H*W, 4)) return 1;
    if (!load_raw("golden_output.bin",&golden_a[0][0][0], CH*H*W, 4)) return 1;

    // int32 -> int8로 좁힙니다. 범위를 벗어나면 여기서 바로 걸러집니다.
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int xv = x_raw[c][h][w];
                int fv = fx_raw[c][h][w];
                if (xv < -128 || xv > 127) { printf("x[%d][%d][%d]=%d out of int8 range\n", c,h,w,xv); return 1; }
                if (fv < -128 || fv > 127) { printf("fx[%d][%d][%d]=%d out of int8 range\n", c,h,w,fv); return 1; }
                x_a[c][h][w]  = (ap_int<8>)xv;
                fx_a[c][h][w] = (ap_int<8>)fv;
            }


    // ★ 실제 스케일 값으로 바꾸세요.
    float x_scale      = 0.03178280357300766f;
    float fx_scale     = 0.018300835541852817f;
    float output_scale = 0.03621446429275152f;

    hls::stream<pix_t> x_s("x_s"), fx_s("fx_s"), out_s("out_s");

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix_t xp, fxp;
            for (int c = 0; c < CH; c++) {
                xp.ch[c]  = x_a[c][h][w];
                fxp.ch[c] = fx_a[c][h][w];
            }
            x_s.write(xp);
            fx_s.write(fxp);
        }
    }

    residual_add_stream(x_s, fx_s, out_s, x_scale, fx_scale, output_scale);

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            pix_t oy = out_s.read();
            for (int c = 0; c < CH; c++) output_a[c][h][w] = oy.ch[c];
        }
    }

    int errors = 0;
    int debug_count = 0;
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int got = output_a[c][h][w];
                int exp = golden_a[c][h][w];
                if (abs(got - exp) > 1) {   // 기존 residual_add도 ±1 허용이었음
                    if (errors < 10) printf("mismatch [%d][%d][%d]: got %d, expected %d\n",
                        c, h, w, got, exp);
                    if (debug_count < 5) {
                        int xr  = x_a[c][h][w];
                        int fxr = fx_a[c][h][w];
                        float xf  = (float)xr  * x_scale;
                        float fxf = (float)fxr * fx_scale;
                        float sum = xf + fxf;
                        float q   = sum / output_scale;
                        printf("  debug: x_raw=%d fx_raw=%d | x_scale=%f fx_scale=%f output_scale=%f\n",
                               xr, fxr, x_scale, fx_scale, output_scale);
                        printf("  debug: x_float=%f fx_float=%f sum=%f q=%f\n",
                               xf, fxf, sum, q);
                        debug_count++;
                    }
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
