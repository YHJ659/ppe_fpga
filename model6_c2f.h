#ifndef MODEL6_C2F_H
#define MODEL6_C2F_H

#include <ap_int.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>

// 데이터 타입 정의
typedef ap_int<8> data_t;
typedef ap_axis<64, 0, 0, 0> axis_t; 
#define FEAT_SIZE 40

// 🌟 서브 모듈 프로토타입 추가
void split_stream_128_to_64x4(
    hls::stream<data_t> &in_strm,
    hls::stream<data_t> &out_bypass,
    hls::stream<data_t> &out_bn_to_conv,
    hls::stream<data_t> &out_bn_to_concat,
    hls::stream<data_t> &out_bn_to_add
);

void add_stream_64(
    hls::stream<data_t> &in1,
    hls::stream<data_t> &in2,
    hls::stream<data_t> &out_strm
);

// 탑 모듈 선언
void model6_c2f_accel(
    hls::stream<axis_t> &in_stream,
    hls::stream<axis_t> &out_stream
);

#endif
