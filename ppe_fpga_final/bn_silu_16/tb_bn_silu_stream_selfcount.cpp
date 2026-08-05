#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>
#include <cstdlib>

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)
#define N_SET 4

typedef struct { ap_int<32> ch[CH]; } in_pix_t;
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;

// ★ 새 시그니처: bn_scale/bn_shift/input_scale/weight_scale/output_scale
//   전부 앞에 [N_SET] 차원이 붙음
void bn_silu_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                    float[N_SET][CH], float[N_SET][CH],
                    float[N_SET], float[N_SET], float[N_SET]);

static ap_int<32> conv_out_a[CH][H][W];
static ap_int<8>  output_a  [CH][H][W];
static int        golden_a  [CH][H][W];   // golden은 int32로 저장돼 있음 (4 B/elem)

static float bn_scale_a [N_SET][CH];
static float bn_shift_a [N_SET][CH];
static float input_scale_a [N_SET];
static float weight_scale_a[N_SET];
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
    static float bn_scale_raw[CH];
    static float bn_shift_raw[CH];

    if (!load_raw("conv_out.bin",      &conv_out_a[0][0][0], CH*H*W, 4)) return 1;
    if (!load_raw("bn_scale.bin",      bn_scale_raw,         CH,     4)) return 1;
    if (!load_raw("bn_shift.bin",      bn_shift_raw,         CH,     4)) return 1;
    if (!load_raw("golden_output.bin", &golden_a[0][0][0],   CH*H*W, 4)) return 1;

    // ★ 실제 양자화 스케일 값 (기존 테스트벤치와 동일)
    float input_scale  = 0.03178280357300766f;
    float weight_scale = 0.0029027743602362205f;
    float output_scale = 0.01974109214121901f;

    // ★ conv3x3 때와 동일한 방식 — 같은 값을 4개 슬롯에 전부 채웁니다.
    // 목적은 call_counter가 0->1->2->3으로 정확히 순환하며 매번
    // my_set 인덱스로 올바른 행을 골라 쓰는지 확인하는 것이고,
    // 4개 서브블록의 실제 개별 값 검증은 시스템 레벨 통합 때 확인합니다.
    for (int k = 0; k < N_SET; k++) {
        for (int c = 0; c < CH; c++) {
            bn_scale_a[k][c] = bn_scale_raw[c];
            bn_shift_a[k][c] = bn_shift_raw[c];
        }
        input_scale_a[k]  = input_scale;
        weight_scale_a[k] = weight_scale;
        output_scale_a[k] = output_scale;
    }

    int total_errors = 0;
    for (int call = 0; call < N_SET; call++) {
        hls::stream<in_pix_t>  in_s("in_s");
        hls::stream<out_pix_t> out_s("out_s");

        for (int h = 0; h < H; h++) {
            for (int w = 0; w < W; w++) {
                in_pix_t px;
                for (int c = 0; c < CH; c++) px.ch[c] = conv_out_a[c][h][w];
                in_s.write(px);
            }
        }

        bn_silu_stream(in_s, out_s, bn_scale_a, bn_shift_a,
                       input_scale_a, weight_scale_a, output_scale_a);

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
                        if (errors < 5)
                            printf("call %d mismatch [%d][%d][%d]: got %d, expected %d\n",
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