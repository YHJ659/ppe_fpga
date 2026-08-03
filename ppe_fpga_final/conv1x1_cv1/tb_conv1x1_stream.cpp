#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define IN_CH   128
#define OUT_CH  128
#define H       40
#define W       40
#define N_PIX   (H * W)

typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;

void conv1x1_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                    ap_int<8>[OUT_CH][IN_CH]);

static int        input_raw [IN_CH][H][W];   // 파일 실측: input도 int32였음 (4 B/elem)
static int        weight_raw[OUT_CH][IN_CH]; // weight도 int32였음 (4 B/elem)
static ap_int<8>  input_a   [IN_CH][H][W];
static ap_int<8>  weight_a  [OUT_CH][IN_CH];
static ap_int<32> output_a  [OUT_CH][H][W];
static long long  golden_a  [OUT_CH][H][W];  // golden은 int64였음 (8 B/elem)

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
    // ★ 파일 이름은 conv1x1 기존 테스트벤치에서 쓰던 실제 이름으로 바꾸세요.
    if (!load_raw("input.bin",         &input_raw[0][0][0],  IN_CH*H*W,     4)) return 1;
    if (!load_raw("weight.bin",        &weight_raw[0][0],     OUT_CH*IN_CH, 4)) return 1;
    if (!load_raw("golden_output.bin", &golden_a[0][0][0],    OUT_CH*H*W,   8)) return 1;

    // int32 -> int8로 좁힙니다. 범위를 벗어나면 여기서 바로 걸러집니다.
    for (int c = 0; c < IN_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int v = input_raw[c][h][w];
                if (v < -128 || v > 127) { printf("input[%d][%d][%d]=%d out of int8 range\n", c,h,w,v); return 1; }
                input_a[c][h][w] = (ap_int<8>)v;
            }
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int ic = 0; ic < IN_CH; ic++) {
            int v = weight_raw[oc][ic];
            if (v < -128 || v > 127) { printf("weight[%d][%d]=%d out of int8 range\n", oc,ic,v); return 1; }
            weight_a[oc][ic] = (ap_int<8>)v;
        }

    hls::stream<in_pix_t>  in_s("in_s");
    hls::stream<out_pix_t> out_s("out_s");

    // 배열 -> 스트림 (채널우선 -> 픽셀우선 전치)
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            in_pix_t px;
            for (int c = 0; c < IN_CH; c++) px.ch[c] = input_a[c][h][w];
            in_s.write(px);
        }
    }

    conv1x1_stream(in_s, out_s, weight_a);

    // 스트림 -> 배열
    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            out_pix_t oy = out_s.read();
            for (int c = 0; c < OUT_CH; c++) output_a[c][h][w] = oy.ch[c];
        }
    }

    int errors = 0;
    for (int c = 0; c < OUT_CH; c++)
        for (int h = 0; h < H; h++)
            for (int w = 0; w < W; w++) {
                int got = output_a[c][h][w];
                int exp = golden_a[c][h][w];
                if (got != exp) {
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
