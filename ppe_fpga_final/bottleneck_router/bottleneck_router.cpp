#include "ap_int.h"
#include "hls_stream.h"

#define CH    64
#define H     40
#define W     40
#define N_PIX (H * W)

typedef struct { ap_int<8> ch[CH]; } pix8_t;

// ============================================================
//  10단계 순서 (Bottleneck1: 1~5, Bottleneck2: 6~10)
//   1) y1        -> conv3x3.in_s                (conv1의 입력)
//   2) bn_out     -> conv3x3.in_s                (conv1 결과 -> conv2 입력, 루프백)
//   3) bn_out     -> residual_add.fx_s           (conv2 결과)
//   4) y1(버퍼)   -> residual_add.x_s            (shortcut)
//   5) res_out    -> concat.y2_s + y2_buf에 저장 (Bottleneck1 출력 = y2)
//   6) y2(버퍼)   -> conv3x3.in_s                (conv1의 입력)
//   7) bn_out     -> conv3x3.in_s                (루프백)
//   8) bn_out     -> residual_add.fx_s
//   9) y2(버퍼)   -> residual_add.x_s            (shortcut)
//  10) res_out    -> concat.y3_s                 (Bottleneck2 출력 = y3)
//
//  conv3x3/bn_silu_64/residual_add는 물리적으로 1벌씩만 존재하니,
//  이 10단계는 절대 겹쳐 돌 수 없고 반드시 순서대로 실행됩니다.
//  그래서 DATAFLOW 없이 순차 루프 10개로 짭니다 (Bottleneck 통합
//  IP에서 DATAFLOW가 하드웨어를 중복 생성했던 문제를 원천 차단).
// ============================================================
void bottleneck_router(
    hls::stream<pix8_t> &y1_s,        // split.y1
    hls::stream<pix8_t> &bn_out_s,    // bn_silu_64.out_s
    hls::stream<pix8_t> &res_out_s,   // residual_add.out_s

    hls::stream<pix8_t> &conv_in_s,   // -> conv3x3.in_s
    hls::stream<pix8_t> &res_x_s,     // -> residual_add.x_s (shortcut)
    hls::stream<pix8_t> &res_fx_s,    // -> residual_add.fx_s
    hls::stream<pix8_t> &y2_out_s,    // -> concat.y2_s
    hls::stream<pix8_t> &y3_out_s     // -> concat.y3_s
) {
#pragma HLS INTERFACE axis port=y1_s
#pragma HLS INTERFACE axis port=bn_out_s
#pragma HLS INTERFACE axis port=res_out_s
#pragma HLS INTERFACE axis port=conv_in_s
#pragma HLS INTERFACE axis port=res_x_s
#pragma HLS INTERFACE axis port=res_fx_s
#pragma HLS INTERFACE axis port=y2_out_s
#pragma HLS INTERFACE axis port=y3_out_s
#pragma HLS INTERFACE s_axilite port=return

    // y1, y2는 shortcut/다음 conv 입력으로 한참 뒤(4~9단계)에 다시
    // 필요하니 프레임 전체를 붙잡아둬야 합니다. concat의 스킵버퍼와
    // 완전히 같은 상황이라 같은 기법(ARRAY_RESHAPE)을 씁니다.
    ap_int<8> y1_buf[CH][H][W];
    ap_int<8> y2_buf[CH][H][W];
#pragma HLS ARRAY_RESHAPE variable=y1_buf cyclic factor=4 dim=3
#pragma HLS ARRAY_RESHAPE variable=y2_buf cyclic factor=4 dim=3

    // ---- 1) y1 도착: conv3x3로 전달하면서 동시에 버퍼에 저장 ----
    STEP1: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP1: p=%d\n", p);
#pragma HLS PIPELINE II=1
        int h = p / W, w = p % W;
        pix8_t px = y1_s.read();
        conv_in_s.write(px);
        for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
            y1_buf[c][h][w] = px.ch[c];
        }
    }

    // ---- 2) bn_out(conv1 결과) 도착: 루프백해서 conv3x3로 다시 ----
    STEP2: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP2: p=%d\n", p);
#pragma HLS PIPELINE II=1
        conv_in_s.write(bn_out_s.read());
    }

    // ---- 3,4) bn_out(conv2 결과) + y1_buf(shortcut) -> residual_add ----
    STEP3_4: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP3_4: p=%d\n", p);
#pragma HLS PIPELINE II=1
        int h = p / W, w = p % W;
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
            xp.ch[c] = y1_buf[c][h][w];
        }
        res_x_s.write(xp);
    }

    // ---- 5) residual_add 결과(y2) 도착: concat으로 + y2_buf에 저장 ----
    STEP5: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP5: p=%d\n", p);
#pragma HLS PIPELINE II=1
        int h = p / W, w = p % W;
        pix8_t px = res_out_s.read();
        y2_out_s.write(px);
        for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
            y2_buf[c][h][w] = px.ch[c];
        }
    }

    // ---- 6) y2_buf -> conv3x3 (Bottleneck2의 conv1 입력) ----
    STEP6: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP6: p=%d\n", p);
#pragma HLS PIPELINE II=1
        int h = p / W, w = p % W;
        pix8_t px;
        for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
            px.ch[c] = y2_buf[c][h][w];
        }
        conv_in_s.write(px);
    }

    // ---- 7) bn_out(conv1 결과) 루프백 ----
    STEP7: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP7: p=%d\n", p);
#pragma HLS PIPELINE II=1
        conv_in_s.write(bn_out_s.read());
    }

    // ---- 8,9) bn_out(conv2 결과) + y2_buf(shortcut) -> residual_add ----
    STEP8_9: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP8_9: p=%d\n", p);
#pragma HLS PIPELINE II=1
        int h = p / W, w = p % W;
        res_fx_s.write(bn_out_s.read());
        pix8_t xp;
        for (int c = 0; c < CH; c++) {
#pragma HLS UNROLL
            xp.ch[c] = y2_buf[c][h][w];
        }
        res_x_s.write(xp);
    }

    // ---- 10) residual_add 결과(y3) 도착: concat으로 (버퍼링 불필요) ----
    STEP10: for (int p = 0; p < N_PIX; p++) {
//    	printf("router STEP10: p=%d\n", p);
#pragma HLS PIPELINE II=1
        y3_out_s.write(res_out_s.read());
    }
}
