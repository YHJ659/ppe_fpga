#include "ap_int.h"
#include "hls_stream.h"

#define CH        64      // branch당 채널 수
#define OUT_CH    256     // 4 * CH
#define H         40
#define W         40
#define N_PIX     (H * W)

// 각 branch(y0~y3)와 최종 출력의 픽셀 타입. 이전 IP들과 폭을 맞췄습니다.
typedef struct { ap_int<8> ch[CH];     } pix_t;      // 512 bit
typedef struct { ap_int<8> ch[OUT_CH]; } out_pix_t;  // 2048 bit

// ============================================================
//  스테이지 1: y0, y1 (split 직후, 가장 먼저 도착)을 프레임 전체
//  BRAM 버퍼에 담습니다. y3와는 무관하게 자기 속도로 빨리 끝납니다.
//  채널을 하나씩 순차로 쓰는 이유는 bn_silu/conv1x1과 동일합니다 —
//  64채널을 다 병렬로 열면 포트가 그만큼 필요해지는데, 여긴 그냥
//  순서대로 쓰기만 하면 되니 직렬로 충분합니다.
// ============================================================
static void buffer01(
    hls::stream<pix_t> &y0_s,
    hls::stream<pix_t> &y1_s,
    ap_int<8> y0_buf[CH][H][W],
    ap_int<8> y1_buf[CH][H][W]
) {
    ap_int<8> p0[2][CH], p1[2][CH];
#pragma HLS ARRAY_PARTITION variable=p0 complete dim=0
#pragma HLS ARRAY_PARTITION variable=p1 complete dim=0

    int h = 0, w = 0;
    BUF01_MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1
        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            pix_t a = y0_s.read();
            pix_t b = y1_s.read();
            UNPACK01: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                p0[par][i] = a.ch[i];
                p1[par][i] = b.ch[i];
            }
        }

        y0_buf[c][h][w] = p0[par][c];
        y1_buf[c][h][w] = p1[par][c];

        if (c == CH - 1) { w++; if (w == W) { w = 0; h++; } }
    }
}

// ============================================================
//  스테이지 2: y2 (Bottleneck0 통과 후 도착)를 프레임 버퍼에 담습니다.
//  y0/y1보다 늦게, y3보다는 먼저 끝납니다. 독립 프로세스라
//  DATAFLOW 상에서 자기 속도로 돌아갑니다.
// ============================================================
static void buffer2(
    hls::stream<pix_t> &y2_s,
    ap_int<8> y2_buf[CH][H][W]
) {
    ap_int<8> p2[2][CH];
#pragma HLS ARRAY_PARTITION variable=p2 complete dim=0

    int h = 0, w = 0;
    BUF2_MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1
        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            pix_t b = y2_s.read();
            UNPACK2: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                p2[par][i] = b.ch[i];
            }
        }

        y2_buf[c][h][w] = p2[par][c];

        if (c == CH - 1) { w++; if (w == W) { w = 0; h++; } }
    }
}

// ============================================================
//  스테이지 3: y3(가장 늦게 도착)를 기다리며, 이미 채워진
//  y0_buf/y1_buf/y2_buf에서 값을 읽어와 256채널로 합칩니다.
//  버퍼 3개는 이 시점엔 이미 완성돼 있으므로 단순 배열 읽기이고,
//  y3만 픽셀 시작(oc==192)에 새로 read합니다.
// ============================================================
static void combine(
    hls::stream<pix_t> &y3_s,
    ap_int<8> y0_buf[CH][H][W],
    ap_int<8> y1_buf[CH][H][W],
    ap_int<8> y2_buf[CH][H][W],
    float scale0, float scale1, float scale2, float scale3,
    float output_scale,
    hls::stream<out_pix_t> &out_s
) {
    ap_int<8>  p3[2][CH];
#pragma HLS ARRAY_PARTITION variable=p3 complete dim=0
    ap_int<8>  obuf[2][OUT_CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    float inv_out = 1.0f / output_scale;
    int h = 0, w = 0;

    COMBINE_MAIN: for (int t = 0; t < N_PIX * OUT_CH; t++) {
#pragma HLS PIPELINE II=1
        int oc  = t % OUT_CH;
        int par = (t / OUT_CH) & 1;
        int branch = oc / CH;   // 0,1,2,3
        int lc     = oc % CH;   // branch 내 채널

        // y3만 픽셀 시작 시점(branch3 진입)에 새로 도착합니다.
        // y0/y1/y2는 이미 버퍼에 다 있으니 read가 필요 없습니다.
        if (oc == 3 * CH) {
            pix_t d = y3_s.read();
            UNPACK3: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                p3[par][i] = d.ch[i];
            }
        }

        ap_int<8> raw;
        float scale;
        if      (branch == 0) { raw = y0_buf[lc][h][w]; scale = scale0; }
        else if (branch == 1) { raw = y1_buf[lc][h][w]; scale = scale1; }
        else if (branch == 2) { raw = y2_buf[lc][h][w]; scale = scale2; }
        else                  { raw = p3[par][lc];       scale = scale3; }

        float v = raw.to_float() * scale;
        float q = v * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][oc] = y_int;

        if (oc == OUT_CH - 1) {
            out_pix_t oy;
            PACKC: for (int i = 0; i < OUT_CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
            w++; if (w == W) { w = 0; h++; }
        }
    }
}

void concat_channel_stream(
    hls::stream<pix_t>  &y0_s,
    hls::stream<pix_t>  &y1_s,
    hls::stream<pix_t>  &y2_s,
    hls::stream<pix_t>  &y3_s,
    float scale0, float scale1, float scale2, float scale3, float output_scale,
    hls::stream<out_pix_t> &out_s
) {
#pragma HLS INTERFACE axis      port=y0_s
#pragma HLS INTERFACE axis      port=y1_s
#pragma HLS INTERFACE axis      port=y2_s
#pragma HLS INTERFACE axis      port=y3_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE s_axilite port=scale0
#pragma HLS INTERFACE s_axilite port=scale1
#pragma HLS INTERFACE s_axilite port=scale2
#pragma HLS INTERFACE s_axilite port=scale3
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=y0_s
#pragma HLS AGGREGATE compact=bit variable=y1_s
#pragma HLS AGGREGATE compact=bit variable=y2_s
#pragma HLS AGGREGATE compact=bit variable=y3_s
#pragma HLS AGGREGATE compact=bit variable=out_s
    // DATAFLOW를 뺐습니다. buffer01/buffer2/combine이 겹쳐 돌던 게
    // 순차 실행(합)으로 바뀝니다 — latency가 약간 늘지만(대략
    // +1ms), 어차피 y3(Bottleneck1까지 통과)가 병목이라 y0/y1/y2가
    // 얼마나 빨리 끝나든 전체엔 영향이 적었습니다.
    //
    // 대신 DATAFLOW의 "배열은 한 프로세스에서만 읽혀야 한다"는
    // 제약이 사라지므로, ARRAY_RESHAPE를 다시 걸 수 있습니다
    // (지난 시도가 실패했던 이유가 바로 그 제약이었습니다).

    // 프레임 전체를 담는 스킵 버퍼입니다. y0/y1/y2 세 개를 합치면
    // 64ch x 40 x 40 x 3벌 = 약 300KB, BRAM18 기준 대략 300개를
    // 씁니다. C2f 구조상 필요한 비용이라 스트림으로 없앨 수 없는
    // 부분입니다.
    //
    // w방향 인접 4개를 하나의 32bit 워드로 묶어 BRAM 폭을 꽉 채워
    // 씁니다. 여전히 BRAM이지만 깊이가 1/4로 줄어 블록 수도 대략
    // 1/4로 줄어듭니다. LUT 비용은 없습니다.
    ap_int<8> y0_buf[CH][H][W];
    ap_int<8> y1_buf[CH][H][W];
    ap_int<8> y2_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=y0_buf cyclic factor=4 dim=3
#pragma HLS ARRAY_RESHAPE variable=y1_buf cyclic factor=4 dim=3
#pragma HLS ARRAY_RESHAPE variable=y2_buf cyclic factor=4 dim=3

    buffer01(y0_s, y1_s, y0_buf, y1_buf);
    buffer2(y2_s, y2_buf);
    combine(y3_s, y0_buf, y1_buf, y2_buf, scale0, scale1, scale2, scale3, output_scale, out_s);
}
