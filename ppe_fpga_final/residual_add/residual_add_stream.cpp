#include "ap_int.h"
#include "hls_stream.h"

#define CH   64
#define H    40
#define W    40
#define N_PIX (H * W)

// x_input(shortcut)과 fx_input(conv+BN+SiLU 결과) 둘 다 이 타입.
// bn_silu_64_stream의 출력과 폭이 같아 그대로 이어집니다.
typedef struct { ap_int<8> ch[CH]; } pix_t;   // 512 bit

void residual_add_stream(
    hls::stream<pix_t> &x_s,    // shortcut 경로
    hls::stream<pix_t> &fx_s,   // conv 경로 F(x)
    hls::stream<pix_t> &out_s,
    float x_scale,
    float fx_scale,
    float output_scale
) {
#pragma HLS INTERFACE axis      port=x_s
#pragma HLS INTERFACE axis      port=fx_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE s_axilite port=x_scale
#pragma HLS INTERFACE s_axilite port=fx_scale
#pragma HLS INTERFACE s_axilite port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=x_s
#pragma HLS AGGREGATE compact=bit variable=fx_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // bn_silu에서 검증된 패턴: 채널당 1사이클씩 처리해 float 연산기를
    // 1벌만 씁니다 (64채널을 다 병렬로 풀면 DSP가 그만큼 늘어납니다).
    // 더블 버퍼로 픽셀 경계의 쓰기/읽기 겹침을 피해 II=1을 유지합니다.
    ap_int<8> xbuf [2][CH];
    ap_int<8> fxbuf[2][CH];
    ap_int<8> obuf [2][CH];
#pragma HLS ARRAY_PARTITION variable=xbuf  complete dim=0
#pragma HLS ARRAY_PARTITION variable=fxbuf complete dim=0
#pragma HLS ARRAY_PARTITION variable=obuf  complete dim=0

    float inv_out = 1.0f / output_scale;

    // t = pixel * CH + c
    MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1

        int c   = t % CH;
        int par = (t / CH) & 1;

        // --- 새 픽셀: 두 스트림을 나란히 읽습니다 ---
        // 두 branch(shortcut vs conv)가 서로 다른 latency를 가질 수
        // 있으므로, 실제 연결 시 FIFO 깊이를 넉넉히 둬 도착 시점
        // 차이를 흡수해야 합니다 (여기 depth는 인터페이스 기본값).
        if (c == 0) {
            pix_t xp  = x_s.read();
            pix_t fxp = fx_s.read();
            UNPACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                xbuf[par][i]  = xp.ch[i];
                fxbuf[par][i] = fxp.ch[i];
            }
        }

        // --- 채널 c 하나: 역양자화 -> 덧셈 -> 재양자화 ---
        float x_float  = xbuf[par][c].to_float()  * x_scale;
        float fx_float = fxbuf[par][c].to_float() * fx_scale;
        float sum = x_float + fx_float;

        float q = sum * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][c] = y_int;

        // --- 마지막 채널: 모아서 내보냄 ---
        if (c == CH - 1) {
            pix_t oy;
            PACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                oy.ch[i] = obuf[par][i];
            }
            out_s.write(oy);
        }
    }
}