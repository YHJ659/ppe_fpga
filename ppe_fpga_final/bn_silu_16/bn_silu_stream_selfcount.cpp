#include "ap_int.h"
#include "hls_math.h"
#include "hls_stream.h"

#define CH      64
#define H       40
#define W       40
#define N_PIX   (H * W)
#define N_SET   4     // m0.cv1, m0.cv2, m1.cv1, m1.cv2 — 프레임당 4회 재사용

// conv3x3의 출력과 동일한 타입이어야 직결됩니다.
typedef struct { ap_int<32> ch[CH]; } in_pix_t;    // 2048 bit
typedef struct { ap_int<8>  ch[CH]; } out_pix_t;   // 512 bit

// ============================================================
//  conv3x3와 같은 문제, 다른 해법 강도.
//
//  bn_scale/bn_shift는 원래도 64개짜리 소형 배열(256B)이라 URAM
//  창고가 필요 없습니다 — 앞에 [N_SET] 차원만 붙이면 그대로
//  BRAM/LUTRAM 크기입니다(4배 해도 1KB, 자원 영향 무시할 수준).
//
//  진짜 손봐야 했던 건 input_scale/weight_scale/output_scale
//  세 개였습니다. 원래 s_axilite 스칼라였는데, 이게 바로
//  "PS가 정확한 타이밍에 레지스터를 써줘야 하는" 그 문제의
//  당사자였습니다. conv3x3의 가중치와 똑같이 [N_SET] 배열로
//  바꿔서 PS가 프레임 시작 전 한 번에 4벌 다 넣어두면, 그 뒤로는
//  call_counter가 매 호출마다 스스로 알맞은 행을 골라 씁니다.
// ============================================================
void bn_silu_stream(
    hls::stream<in_pix_t>  &in_s,
    hls::stream<out_pix_t> &out_s,
    float bn_scale[N_SET][CH],
    float bn_shift[N_SET][CH],
    float input_scale[N_SET],
    float weight_scale[N_SET],
    float output_scale[N_SET]
) {
#pragma HLS INTERFACE axis      port=in_s
#pragma HLS INTERFACE axis      port=out_s
#pragma HLS INTERFACE bram      port=bn_scale
#pragma HLS INTERFACE bram      port=bn_shift
#pragma HLS INTERFACE bram      port=input_scale
#pragma HLS INTERFACE bram      port=weight_scale
#pragma HLS INTERFACE bram      port=output_scale
#pragma HLS INTERFACE s_axilite port=return
#pragma HLS AGGREGATE compact=bit variable=in_s
#pragma HLS AGGREGATE compact=bit variable=out_s

    // ★ conv3x3와 동일한 자체 카운팅. static이라 ap_start(Auto Restart)
    // 될 때마다 값이 유지되며 스스로 순번을 셉니다. PS는 프레임 시작 전
    // 딱 한 번 5개 배열을 전부 로드해두면, 그 뒤로 개입할 필요가 없습니다.
    static int call_counter = 0;
    int my_set = call_counter % N_SET;
    call_counter++;

    float in_w_scale = input_scale[my_set] * weight_scale[my_set];
    float inv_out    = 1.0f / output_scale[my_set];

    // ============================================================
    //  더블 버퍼: 픽셀 버퍼를 c==0에서 쓰고 그 뒤 63번 읽습니다.
    //  (기존 확정본과 완전히 동일 — 이 부분은 변경 없음)
    // ============================================================
    ap_int<32> ibuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=ibuf complete dim=0

    ap_int<8>  obuf[2][CH];
#pragma HLS ARRAY_PARTITION variable=obuf complete dim=0

    // t = pixel * CH + c
    MAIN: for (int t = 0; t < N_PIX * CH; t++) {
#pragma HLS PIPELINE II=1

        int c   = t % CH;
        int par = (t / CH) & 1;

        if (c == 0) {
            in_pix_t px = in_s.read();
            UNPACK: for (int i = 0; i < CH; i++) {
#pragma HLS UNROLL
                ibuf[par][i] = px.ch[i];
            }
        }

        // bn_scale[my_set][c] / bn_shift[my_set][c] — my_set은 이번 호출
        // 내내 고정값이라 주소 계산만 살짝 늘어날 뿐, 사이클당 읽기 1회는
        // 기존과 동일합니다 (자원/타이밍 영향 없음).
        float x_float   = ibuf[par][c].to_float() * in_w_scale;
        float bn_out    = x_float * bn_scale[my_set][c] + bn_shift[my_set][c];
        float sigmoid_x = 1.0f / (1.0f + hls::exp(-bn_out));
        float silu_out  = bn_out * sigmoid_x;

        float q = silu_out * inv_out;
        int y_int = (int)(q + (q >= 0 ? 0.5f : -0.5f));
        if (y_int >  127) y_int =  127;
        if (y_int < -128) y_int = -128;
        obuf[par][c] = y_int;

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