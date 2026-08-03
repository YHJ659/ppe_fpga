#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define IN_CH   64
#define OUT_CH  64
#define IN_H    40
#define IN_W    40
#define K       3

typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;

void conv3x3_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                    ap_int<8>[OUT_CH][IN_CH][K][K], int layer_id);

static ap_int<8>  input_a [IN_CH][IN_H][IN_W];
static ap_int<8>  weight_a[OUT_CH][IN_CH][K][K];
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
    // 이전에 검증된 실제 포맷: input/weight = int32(4B), golden = int64(8B)
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
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int ic = 0; ic < IN_CH; ic++)
            for (int kh = 0; kh < K; kh++)
                for (int kw = 0; kw < K; kw++) {
                    int v = weight_raw[oc][ic][kh][kw];
                    if (v < -128 || v > 127) { printf("weight out of int8 range: %d\n", v); return 1; }
                    weight_a[oc][ic][kh][kw] = (ap_int<8>)v;
                }

    hls::stream<in_pix_t>  in_s("in_s");
    hls::stream<out_pix_t> out_s("out_s");

    for (int h = 0; h < IN_H; h++) {
        for (int w = 0; w < IN_W; w++) {
            in_pix_t px;
            for (int c = 0; c < IN_CH; c++) px.ch[c] = input_a[c][h][w];
            in_s.write(px);
        }
    }

    // ★ layer_id: 시분할 재사용 시 어느 레이어인지 구분하는 값.
    //   단일 레이어만 검증하는 이 테스트벤치에서는 0으로 고정합니다.
    //   여러 레이어를 이어서 테스트하려면 이 값을 바꿔가며 conv3x3_stream을
    //   반복 호출하고, 그때마다 다른 weight를 넣어 캐싱 전환을 확인하세요.
    int layer_id = 0;
    conv3x3_stream(in_s, out_s, weight_a, layer_id);

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
                    if (errors < 10)
                        printf("mismatch [%d][%d][%d]: got %lld, expected %lld\n",
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