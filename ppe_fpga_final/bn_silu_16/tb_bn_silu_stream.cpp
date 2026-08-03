#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>
#include <cstdlib>

#define CH   64
#define H    40
#define W    40
#define N_PIX (H * W)

typedef struct { ap_int<32> ch[CH]; } in_pix_t;
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;

void bn_silu_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                    float[CH], float[CH], float, float, float);

static ap_int<32> conv_out_a[CH][H][W];
static ap_int<8>  output_a  [CH][H][W];
static int        golden_a  [CH][H][W];   // golden은 int32로 저장돼 있음 (4 B/elem)
static float      bn_scale_a[CH];
static float      bn_shift_a[CH];

// ★ 기존 bn_silu 테스트벤치의 로드 함수를 그대로 쓰세요.
//   포맷(바이트/원소)이 안 맞으면 값이 전부 어긋납니다.
//   아래는 크기 진단만 넣어둔 예시입니다.
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
    // ---- 파일 로드 (이름/포맷은 기존 테스트벤치에 맞춰 조정) ----
    if (!load_raw("conv_out.bin",     &conv_out_a[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("bn_scale.bin",     bn_scale_a,           CH,     4)) return 1;
    if (!load_raw("bn_shift.bin",     bn_shift_a,           CH,     4)) return 1;
    if (!load_raw("golden_output.bin",&golden_a[0][0][0],   CH*H*W, 4)) return 1;

    // ★ 실제 양자화 스케일 값으로 바꾸세요 (기존 테스트벤치와 동일하게)
    float input_scale  = 0.03178280357300766f;
    float weight_scale = 0.0029027743602362205f;
    float output_scale = 0.01974109214121901f;


    hls::stream<in_pix_t>  in_s("in_s");
    hls::stream<out_pix_t> out_s("out_s");

    // ---- 배열 -> 스트림 (채널우선 → 픽셀우선 전치) ----
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            in_pix_t px;
            for (int c = 0; c < CH; c++) px.ch[c] = conv_out_a[c][h][w];
            in_s.write(px);
        }
    }

    bn_silu_stream(in_s, out_s, bn_scale_a, bn_shift_a,
                   input_scale, weight_scale, output_scale);

    // ---- 스트림 -> 배열 ----
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            out_pix_t oy = out_s.read();
            for (int c = 0; c < CH; c++) output_a[c][h][w] = oy.ch[c];
        }
    }

    // ---- golden 비교 (기존과 동일하게 ±1 허용) ----
    int errors = 0;
    for (int c = 0; c < CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int got = output_a[c][h][w];
                int exp = golden_a[c][h][w];                if (abs(got - exp) > 1) {
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
