#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>
#include <cstdlib>

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)
#define N_SET 2

typedef struct { ap_int<8> ch[CH]; } pix_t;

// ★ 새 시그니처: x_scale/fx_scale/output_scale 전부 [N_SET] 배열
void residual_add_stream(hls::stream<pix_t>&, hls::stream<pix_t>&, hls::stream<pix_t>&,
                         float[N_SET], float[N_SET], float[N_SET]);

static int       x_raw    [CH][H][W];   // 파일 실측: int32 (4 B/elem)
static int       fx_raw   [CH][H][W];
static ap_int<8> x_a     [CH][H][W];
static ap_int<8> fx_a    [CH][H][W];
static ap_int<8> output_a[CH][H][W];
static int       golden_a[CH][H][W];

static float x_scale_a     [N_SET];
static float fx_scale_a    [N_SET];
static float output_scale_a[N_SET];

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
    if (!load_raw("x_input.bin",      &x_raw[0][0][0],    CH*H*W, 4)) return 1;
    if (!load_raw("fx_input.bin",     &fx_raw[0][0][0],   CH*H*W, 4)) return 1;
    if (!load_raw("golden_output.bin",&golden_a[0][0][0], CH*H*W, 4)) return 1;

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

    float x_scale      = 0.03178280357300766f;
    float fx_scale     = 0.018300835541852817f;
    float output_scale = 0.03621446429275152f;

    // ★ conv3x3/bn_silu_64와 동일 방식: 같은 값을 두 슬롯에 채워
    // call_counter가 0->1로 정확히 순환하는지 확인합니다.
    for (int k = 0; k < N_SET; k++) {
        x_scale_a[k]      = x_scale;
        fx_scale_a[k]     = fx_scale;
        output_scale_a[k] = output_scale;
    }

    int total_errors = 0;
    for (int call = 0; call < N_SET; call++) {
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

        residual_add_stream(x_s, fx_s, out_s, x_scale_a, fx_scale_a, output_scale_a);

        for (int h = 0; h < H; h++) {
            for (int w = 0; w < W; w++) {
                pix_t oy = out_s.read();
                for (int c = 0; c < CH; c++) output_a[c][h][w] = oy.ch[c];
            }
        }

        int errors = 0;
        for (int c = 0; c < CH; c++)
            for (int h = 0; h < H; h++)
                for (int w = 0; w < W; w++) {
                    int got = output_a[c][h][w];
                    int exp = golden_a[c][h][w];
                    if (abs(got - exp) > 1) {
                        if (errors < 5) printf("call %d mismatch [%d][%d][%d]: got %d, expected %d\n",
                            call, c, h, w, got, exp);
                        errors++;
                    }
                }

        if (!out_s.empty()) {
            printf("call %d WARNING: output stream still has %d elements\n",
                   call, (int)out_s.size());
            errors++;
        }

        printf("call %d (my_set=%d 예상): %s (%d mismatches)\n",
               call, call % N_SET, errors == 0 ? "PASS" : "FAIL", errors);
        total_errors += errors;
    }

    printf(total_errors == 0 ? "TEST PASSED\n" : "TEST FAILED: %d total mismatches\n",
           total_errors);
    return total_errors ? 1 : 0;
}