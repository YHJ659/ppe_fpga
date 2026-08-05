#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define IN_CH   64
#define OUT_CH  64
#define IN_H    40
#define IN_W    40
#define K       3
#define N_SET   4

typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;

// ★ 새 시그니처: layer_id 없음, weight에 [N_SET] 차원 추가
void conv3x3_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                    ap_int<8>[N_SET][OUT_CH][IN_CH][K][K]);

static ap_int<8>  input_a [IN_CH][IN_H][IN_W];
static ap_int<8>  weight_a[N_SET][OUT_CH][IN_CH][K][K];
static ap_int<32> output_a[OUT_CH][IN_H][IN_W];
static long long  golden_a[OUT_CH][IN_H][IN_W];

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
    static int input_raw [IN_CH][IN_H][IN_W];
    static int weight_raw[OUT_CH][IN_CH][K][K];

    if (!load_raw("input.bin",  &input_raw[0][0][0],    IN_CH * IN_H * IN_W,    4)) return 1;
    if (!load_raw("weight.bin", &weight_raw[0][0][0][0], OUT_CH * IN_CH * K * K, 4)) return 1;
    if (!load_raw("golden_output.bin", &golden_a[0][0][0], OUT_CH * IN_H * IN_W, 8)) return 1;

    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < IN_H; h++)
            for (int w = 0; w < IN_W; w++) {
                int v = input_raw[c][h][w];
                if (v < -128 || v > 127) { printf("input[%d][%d][%d]=%d out of int8 range\n", c,h,w,v); return 1; }
                input_a[c][h][w] = (ap_int<8>)v;
            }

    // ★ 같은 가중치를 4개 슬롯에 전부 채움 — 이번 테스트의 목적은
    // "call_counter가 0,1,2,3,0,1,... 로 정확히 순환하며 weight_bank
    // ->local_weight 전환이 매번 올바로 일어나는가"이지, 4개 서브블록의
    // 실제 개별 가중치 정합성이 아닙니다(그건 시스템 레벨 통합 때 확인).
    // 4벌이 전부 같으니 어느 슬롯이 선택되어도 golden과 같아야 합니다.
    for (int k = 0; k < N_SET; k++)
        for (int oc = 0; oc < OUT_CH; oc++)
            for (int ic = 0; ic < IN_CH; ic++)
                for (int kh = 0; kh < K; kh++)
                    for (int kw = 0; kw < K; kw++) {
                        int v = weight_raw[oc][ic][kh][kw];
                        if (v < -128 || v > 127) { printf("weight out of int8 range: %d\n", v); return 1; }
                        weight_a[k][oc][ic][kh][kw] = (ap_int<8>)v;
                    }

    // ★ 실제 프레임처럼 4번(m0.cv1, m0.cv2, m1.cv1, m1.cv2 순서를 흉내)
    // 연속으로 호출합니다. call_counter가 static이라 이 4번의 호출을
    // 거치며 0->1->2->3으로 스스로 순환해야 합니다.
    int total_errors = 0;
    for (int call = 0; call < N_SET; call++) {
        hls::stream<in_pix_t>  in_s("in_s");
        hls::stream<out_pix_t> out_s("out_s");

        for (int h = 0; h < IN_H; h++) {
            for (int w = 0; w < IN_W; w++) {
                in_pix_t px;
                for (int c = 0; c < IN_CH; c++) px.ch[c] = input_a[c][h][w];
                in_s.write(px);
            }
        }

        conv3x3_stream(in_s, out_s, weight_a);

        for (int h = 0; h < IN_H; h++) {
            for (int w = 0; w < IN_W; w++) {
                out_pix_t oy = out_s.read();
                for (int c = 0; c < OUT_CH; c++) output_a[c][h][w] = oy.ch[c];
            }
        }

        int errors = 0;
        for (int c = 0; c < OUT_CH; c++)
            for (int h = 0; h < IN_H; h++)
                for (int w = 0; w < IN_W; w++) {
                    long long got = output_a[c][h][w];
                    long long exp = golden_a[c][h][w];
                    if (got != exp) {
                        if (errors < 5)
                            printf("call %d mismatch [%d][%d][%d]: got %lld, expected %lld\n",
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
