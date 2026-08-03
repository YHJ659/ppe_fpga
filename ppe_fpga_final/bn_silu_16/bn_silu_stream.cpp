#include "ap_int.h"
#include "hls_math.h"
#include "hls_stream.h"

#define CH   64
#define H    40
#define W    40
#define N_PIX (H * W)

// conv3x3의 출력과 동일한 타입이어야 직결됩니다.
typedef struct { ap_int<32> ch[CH]; } in_pix_t;    // 2048 bit
// 다음 단(residual_add, split 등)으로 넘길 int8 픽셀.
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;   // 512 bit

void bn_silu_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    float bn_scale[CH],
    float bn_shift[CH],
    float input_scale,
    float weight_scale,
    float output_scale
) {
#pragma HLS INTERFACE axis      port=in_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=bn_scale
#pragma HLS INTERFACE bram      port=bn_shift
#pragma HLS INTERFACE s_axilite port=input_scale
#pragma HLS INTERFACE s_axilite port=weight_scale
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // ============================================================
    //  더블 버퍼: 픽셀 버퍼를 c==0에서 쓰고 그 뒤 63번 읽습니다.
    //  단일 버퍼면 다음 픽셀의 쓰기가 이전 픽셀의 읽기와 겹쳐
    //  HLS가 II를 3으로 낮춥니다 (conv3x3에서 겪은 그 문제).
    //  픽셀 인덱스의 홀짝으로 버퍼를 번갈아 쓰면 충돌이 사라집니다.
    // ============================================================
    ap_int<32> ibuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=ibuf complete dim=0

    ap_int<8>  obuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    // 스케일 상수는 루프 밖에서 한 번만 곱해둡니다.
    float in_w_scale = input_scale * weight_scale;
    float inv_out    = 1.0f / output_scale;

    // t = pixel * CH + c  — 루프 하나로 병합해 파이프라인을 단순하게
    MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1

        int c   = t % CH;
        int par = (t / CH) & 1;   // 현재 픽셀의 버퍼 번호

        // --- 새 픽셀 도착: 32비트 x 64채널을 통째로 언팩 ---
        if (c == 0) {
            in_pix_t px = in_s.read();
            UNPACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                ibuf[par][i] = px.ch[i];
            }
        }

        // --- 채널 c 하나 처리 (exp 유닛 1개만 생성됨) ---
        float x_float   = ibuf[par][c].to_float() * in_w_scale;
        float bn_out    = x_float * bn_scale[c] + bn_shift[c];
        float sigmoid_x = 1.0f / (1.0f + hls::exp(-bn_out));
        float silu_out  = bn_out * sigmoid_x;

        float q = silu_out * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][c] = y_int;

        // --- 마지막 채널: 64개를 모아 한 픽셀로 내보냄 ---
        if (c == CH - 1) {
            out_pix_t oy;
            PACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
        }
    }
}