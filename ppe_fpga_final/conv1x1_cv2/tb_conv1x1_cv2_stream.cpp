#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define IN_CH   256
#define OUT_CH  128
#define H       40
#define W       40
#define N_PIX   (H * W)

typedef struct { ap_int<8>  ch[IN_CH];  } in_pix_t;
typedef struct { ap_int<32> ch[OUT_CH]; } out_pix_t;

void conv1x1_cv2_stream(hls::stream<in_pix_t>&, hls::stream<out_pix_t>&,
                        ap_int<8>[OUT_CH][IN_CH]);

static int        input_raw [IN_CH][H][W];   // 파일 실측: int32였음 (4 B/elem)
static int        weight_raw[OUT_CH][IN_CH];
static ap_int<8>  input_a  [IN_CH][H][W];
static ap_int<8>  weight_a [OUT_CH][IN_CH];
static ap_int<32> output_a [OUT_CH][H][W];
static long long  golden_a [OUT_CH][H][W];

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
    // ★★★ 지금 golden 스크립트(bn_silu용)는 conv_out.bin(conv 결과)만
    //     저장하고, conv1x1 자체를 검증할 quantized input.bin과
    //     weight.bin은 저장하지 않습니다. 아래 두 가지 중 하나가 필요합니다:
    //
    //     1) cv1 때 쓰신 별도의 conv1x1 golden 스크립트가 있다면, 그걸
    //        cv2용(model.6.cv2, IN_CH=256)으로 복사해 input_int8.bin,
    //        weight_int8.bin, golden(int64, raw conv sum)을 저장하세요.
    //     2) 없다면 Batch_normalization_golden_reference_cv2.py 안의
    //        input_int8, weight_int8 텐서에 .tofile(...) 한 줄씩만
    //        추가해서 저장하시면 됩니다.
    //
    //     아래 파일명/dtype은 cv1 테스트벤치와 같은 관례를 따른
    //     가정치입니다. 실제 로그의 B/elem을 보고 맞춰주세요.
    // 로그 실측: input/weight 전부 int32(4 B/elem)였습니다.
    if (!load_raw("input.bin",         &input_raw[0][0][0], IN_CH*H*W,     4)) return 1;
    if (!load_raw("weight.bin",        &weight_raw[0][0],    OUT_CH*IN_CH, 4)) return 1;
    if (!load_raw("golden_output.bin", &golden_a[0][0][0],   OUT_CH*H*W,   8)) return 1;

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

    for (int h = 0; h < H; h++) {
        for (int w = 0; w < W; w++) {
            in_pix_t px;
            for (int c = 0; c < IN_CH; c++) px.ch[c] = input_a[c][h][w];
            in_s.write(px);
        }
    }

    conv1x1_cv2_stream(in_s, out_s, weight_a);

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
                long long got = output_a[c][h][w];
                long long exp = golden_a[c][h][w];
                if (got != exp) {
                    if (errors < 10) printf("mismatch [%d][%d][%d]: got %lld, expected %lld\n",
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
