#include "ap_int.h"
#include "hls_stream.h"
#include <cstdio>

#define CH    128
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<32> ch[CH]; } pix128_32_t;
typedef struct { ap_int<8>  ch[CH]; } pix128_8_t;

void bn128_router(
    hls::stream<pix128_32_t> &cv1_out_s,
    hls::stream<pix128_32_t> &cv2_out_s,
    hls::stream<pix128_8_t>  &bn_out_s,
    hls::stream<pix128_32_t> &bn_in_s,
    hls::stream<pix128_8_t>  &split_in_s,
    hls::stream<pix128_8_t>  &final_out_s
);

int main() {
    hls::stream<pix128_32_t> cv1_out_s("cv1_out_s"), cv2_out_s("cv2_out_s");
    hls::stream<pix128_8_t>  bn_out_s("bn_out_s");
    hls::stream<pix128_32_t> bn_in_s("bn_in_s");
    hls::stream<pix128_8_t>  split_in_s("split_in_s"), final_out_s("final_out_s");

    // ---- 입력 준비: cv1/cv2 각각 구분되는 패턴으로 채움 ----
    for (int p = 0; p < N_PIX; p++) {
        pix128_32_t a, b;
        for (int c = 0; c < CH; c++) { a.ch[c] = p + c; b.ch[c] = 1000 + p + c; }
        cv1_out_s.write(a);
        cv2_out_s.write(b);
    }

    // ---- bn_out_s를 라우터가 읽을 순서대로(STEP2용 1600개, STEP4용 1600개)
    //      미리 계산해 채워둡니다. 실제 bn_silu_128이 낼 값을 흉내낸
    //      구분되는 패턴입니다 (라우터는 이 값을 그대로 통과시킬 뿐이라
    //      실제 연산 흉내는 불필요합니다). ----
    static pix128_8_t bn1_expected[N_PIX], bn2_expected[N_PIX];
    for (int p = 0; p < N_PIX; p++) {
        pix128_8_t d1, d2;
        for (int c = 0; c < CH; c++) {
            d1.ch[c] = (p + c) % 100;         // 1번째 호출(cv1측) 결과 흉내
            d2.ch[c] = (2000 + p + c) % 100;  // 2번째 호출(cv2측) 결과 흉내
        }
        bn1_expected[p] = d1;
        bn2_expected[p] = d2;
        bn_out_s.write(d1);
    }
    for (int p = 0; p < N_PIX; p++) {
        bn_out_s.write(bn2_expected[p]);
    }

    bn128_router(cv1_out_s, cv2_out_s, bn_out_s, bn_in_s, split_in_s, final_out_s);

    // bn_in_s는 이 테스트에서 소비하는 쪽이 없어도 됩니다(무한 FIFO라
    // 그냥 쌓여있을 뿐, bottleneck_router 때와 같은 무해한 leftover).

    int errors = 0;
    for (int p = 0; p < N_PIX; p++) {
        pix128_8_t got = split_in_s.read();
        for (int c = 0; c < CH; c++) {
            if (got.ch[c] != bn1_expected[p].ch[c]) {
                if (errors < 10) printf("split_in_s mismatch p=%d c=%d: got %d, expected %d\n",
                    p, c, (int)got.ch[c], (int)bn1_expected[p].ch[c]);
                errors++;
            }
        }
    }
    for (int p = 0; p < N_PIX; p++) {
        pix128_8_t got = final_out_s.read();
        for (int c = 0; c < CH; c++) {
            if (got.ch[c] != bn2_expected[p].ch[c]) {
                if (errors < 10) printf("final_out_s mismatch p=%d c=%d: got %d, expected %d\n",
                    p, c, (int)got.ch[c], (int)bn2_expected[p].ch[c]);
                errors++;
            }
        }
    }

    printf(errors == 0 ? "TEST PASSED\n" : "TEST FAILED: %d mismatches\n", errors);
    return errors ? 1 : 0;
}