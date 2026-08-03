#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>
#include <cstdlib>

#define CH   128
#define H    40
#define W    40
#define N_PIX (H * W)

typedef struct { ap_int<32> ch[CH]; } in_pix_t;
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;

void bn_silu_128_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                        float[CH], float[CH], float, float, float);

static ap_int<32> conv_out_a[CH][H][W];
static ap_int<8>  output_a  [CH][H][W];
static int        golden_a  [CH][H][W];   // golden이 int32였던 bn_silu_64 사례 참고. 크기 진단으로 재확인.
static float      bn_scale_a[CH];
static float      bn_shift_a[CH];

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
    // ★ 파일 이름은 bn_silu_128용 실제 파일명으로 바꾸세요.
    //   진단 출력의 B/elem 값을 보고 4가 아니면 elem_bytes와 배열 타입을 맞추세요.
    if (!load_raw("conv_out.bin",     &conv_out_a[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("bn_scale.bin",     bn_scale_a,           CH,     4)) return 1;
    if (!load_raw("bn_shift.bin",     bn_shift_a,           CH,     4)) return 1;
    if (!load_raw("golden_output.bin",&golden_a[0][0][0],   CH*H*W, 4)) return 1;

    // ★ bn_silu_128 기존 테스트벤치의 실제 스케일 값으로 바꾸세요.
    float input_scale  = 0.03091546118728758f;
    float weight_scale = 0.0029566006397637795f;
    float output_scale = 0.04751440108291746f;

    hls::stream<in_pix_t>  in_s("in_s");
    hls::stream<out_pix_t> out_s("out_s");

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            in_pix_t px;
            for (int c = 0; c < CH; c++) px.ch[c] = conv_out_a[c][h][w];
            in_s.write(px);
        }
    }

    bn_silu_128_stream(in_s, out_s, bn_scale_a, bn_shift_a,
                        input_scale, weight_scale, output_scale);

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            out_pix_t oy = out_s.read();
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
                    if (errors < 10)
                        printf("mismatch [%d][%d][%d]: got %d, expected %d\n",
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