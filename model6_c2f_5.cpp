#include <ap_int.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>
#include "model6_c2f.h"

typedef ap_int<8> data_t;    
typedef ap_int<32> acc_t;    
typedef ap_axis<64, 0, 0, 0> axis_t; 

const data_t silu_lut[256] = {
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
    96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127
};

// --------------------------------------------------------
// II Violation 수정된 read_input
// --------------------------------------------------------
void read_input(hls::stream<axis_t> &in_stream, hls::stream<data_t> &strm_input) {
    int total_packets = (128 * FEAT_SIZE * FEAT_SIZE) / 8;

    for (int i = 0; i < total_packets; i++) {
        // 64-bit AXI 데이터 1회 읽기
        axis_t pkt = in_stream.read();

        // 8개의 8-bit 데이터를 스트림에 순차적으로 write (II=1 달성)
        for (int j = 0; j < 8; j++) {
            #pragma HLS PIPELINE II=1
            data_t byte_val = (data_t)((pkt.data >> (j * 8)) & 0xFF);
            strm_input.write(byte_val);
        }
    }
}

// --------------------------------------------------------
// II Violation 수정된 write_output
// --------------------------------------------------------
void write_output(hls::stream<data_t> &strm_cv2_out, hls::stream<axis_t> &out_stream) {
    int total_packets = (128 * FEAT_SIZE * FEAT_SIZE) / 8;

    for (int i = 0; i < total_packets; i++) {
        ap_uint<64> packed_data = 0;
        
        // 스트림에서 8개 읽어오기 (II=1 달성)
        for (int j = 0; j < 8; j++) {
            #pragma HLS PIPELINE II=1
            ap_uint<8> val = strm_cv2_out.read();
            packed_data |= ((ap_uint<64>)val << (j * 8));
        }

        // 64-bit 패킷 구성 및 AXI 스트림 전송
        axis_t pkt;
        pkt.data = packed_data;
        pkt.keep = -1;
        pkt.strb = -1;
        pkt.user = 0;
        pkt.id = 0;
        pkt.dest = 0;
        pkt.last = (i == total_packets - 1) ? 1 : 0;
        
        out_stream.write(pkt);
    }
}

void conv1x1_stream(
    hls::stream<data_t> &in_strm, 
    hls::stream<data_t> &out_strm, 
    const data_t weight[], 
    const acc_t bias[], 
    int in_ch, 
    int out_ch
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        data_t in_buf[256];
        #pragma HLS ARRAY_PARTITION variable=in_buf cyclic factor=16

        for (int ic = 0; ic < in_ch; ic++) {
            #pragma HLS PIPELINE II=1
            in_buf[ic] = in_strm.read();
        }

        for (int oc = 0; oc < out_ch; oc++) {
            #pragma HLS PIPELINE II=1
            acc_t mac = bias[oc];
            for (int ic = 0; ic < in_ch; ic++) {
                #pragma HLS UNROLL factor=16
                int w_idx = (oc * in_ch) + ic;
                mac += in_buf[ic] * weight[w_idx];
            }
            data_t q_val = (data_t)(mac >> 8); 
            out_strm.write(silu_lut[(unsigned char)q_val]);
        }
    }
}

void conv3x3_stream(
    hls::stream<data_t> &in_strm, 
    hls::stream<data_t> &out_strm, 
    const data_t weight[], 
    const acc_t bias[], 
    int ch
) {
    data_t line_buf[64][2][FEAT_SIZE];
    #pragma HLS ARRAY_PARTITION variable=line_buf dim=1 complete
    #pragma HLS ARRAY_PARTITION variable=line_buf dim=2 complete

    data_t window[64][3][3];
    #pragma HLS ARRAY_PARTITION variable=window dim=1 complete
    #pragma HLS ARRAY_PARTITION variable=window dim=2 complete
    #pragma HLS ARRAY_PARTITION variable=window dim=3 complete

    for (int h = 0; h < FEAT_SIZE; h++) {
        for (int w = 0; w < FEAT_SIZE; w++) {
            for (int c = 0; c < ch; c++) {
                #pragma HLS PIPELINE II=1

                data_t in_pixel = in_strm.read();

                for (int i = 0; i < 3; i++) {
                    #pragma HLS UNROLL
                    window[c][i][0] = window[c][i][1];
                    window[c][i][1] = window[c][i][2];
                }

                window[c][0][2] = line_buf[c][0][w];
                window[c][1][2] = line_buf[c][1][w];
                window[c][2][2] = in_pixel;

                line_buf[c][0][w] = line_buf[c][1][w];
                line_buf[c][1][w] = in_pixel;

                acc_t mac = bias[c];
                for (int kh = 0; kh < 3; kh++) {
                    #pragma HLS UNROLL
                    for (int kw = 0; kw < 3; kw++) {
                        #pragma HLS UNROLL
                        int r = h + kh - 1;
                        int col = w + kw - 1;
                        data_t pix = 0;
                        if (r >= 0 && r < FEAT_SIZE && col >= 0 && col < FEAT_SIZE) {
                            pix = window[c][kh][kw];
                        }
                        int w_idx = (c * 9) + (kh * 3) + kw;
                        mac += pix * weight[w_idx];
                    }
                }

                data_t q_val = (data_t)(mac >> 8);
                data_t act_val = silu_lut[(unsigned char)q_val];

                out_strm.write(act_val);
            }
        }
    }
}

void split_stream_128_to_64x4(
    hls::stream<data_t> &in_strm,
    hls::stream<data_t> &out_bypass,
    hls::stream<data_t> &out_bn_to_conv,
    hls::stream<data_t> &out_bn_to_concat,
    hls::stream<data_t> &out_bn_to_add
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_bypass.write(in_strm.read());
        }
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            data_t val = in_strm.read();
            out_bn_to_conv.write(val);
            out_bn_to_concat.write(val);
            out_bn_to_add.write(val);
        }
    }
}

// 🌟 신규 추가: 스트림 복사 전용 함수
void duplicate_stream_64(
    hls::stream<data_t> &in_strm,
    hls::stream<data_t> &out1,
    hls::stream<data_t> &out2
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            data_t val = in_strm.read();
            out1.write(val);
            out2.write(val);
        }
    }
}

void concat_stream_64x4_to_256(
    hls::stream<data_t> &strm0,
    hls::stream<data_t> &strm1,
    hls::stream<data_t> &strm2,
    hls::stream<data_t> &strm3,
    hls::stream<data_t> &out_concat
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm0.read());
        }
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm1.read());
        }
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm2.read());
        }
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm3.read());
        }
    }
}

void add_stream_64(
    hls::stream<data_t> &in1,
    hls::stream<data_t> &in2,
    hls::stream<data_t> &out_strm
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            data_t v1 = in1.read();
            data_t v2 = in2.read();
            out_strm.write(v1 + v2);
        }
    }
}

void model6_c2f_accel(
    hls::stream<axis_t> &in_stream,
    hls::stream<axis_t> &out_stream
) {
    #pragma HLS INTERFACE axis port=in_stream
    #pragma HLS INTERFACE axis port=out_stream
    #pragma HLS INTERFACE s_axilite port=return bundle=CTRL_BUS

    hls::stream<data_t> strm_input("strm_input");
    #pragma HLS STREAM variable=strm_input depth=4096

    hls::stream<data_t> strm_cv1_out("strm_cv1_out");
    #pragma HLS STREAM variable=strm_cv1_out depth=4096

    hls::stream<data_t> strm_bypass("strm_bypass");
    #pragma HLS STREAM variable=strm_bypass depth=131072

    hls::stream<data_t> strm_bn1_direct("strm_bn1_direct");
    #pragma HLS STREAM variable=strm_bn1_direct depth=131072

    hls::stream<data_t> strm_bn1_to_add("strm_bn1_to_add");
    #pragma HLS STREAM variable=strm_bn1_to_add depth=131072

    hls::stream<data_t> strm_bn1_in("strm_bn1_in");
    #pragma HLS STREAM variable=strm_bn1_in depth=16384

    hls::stream<data_t> strm_bn1_out("strm_bn1_out");
    #pragma HLS STREAM variable=strm_bn1_out depth=16384

    // 🌟 분기용 스트림 2개 신규 정의
    hls::stream<data_t> strm_bn1_out_to_conv("strm_bn1_out_to_conv");
    #pragma HLS STREAM variable=strm_bn1_out_to_conv depth=16384

    hls::stream<data_t> strm_bn1_out_to_concat("strm_bn1_out_to_concat");
    #pragma HLS STREAM variable=strm_bn1_out_to_concat depth=16384

    hls::stream<data_t> strm_bn2_conv_out("strm_bn2_conv_out");
    #pragma HLS STREAM variable=strm_bn2_conv_out depth=16384

    hls::stream<data_t> strm_bn2_out("strm_bn2_out");
    #pragma HLS STREAM variable=strm_bn2_out depth=16384

    hls::stream<data_t> strm_concat_out("strm_concat_out");
    #pragma HLS STREAM variable=strm_concat_out depth=8192

    hls::stream<data_t> strm_cv2_out("strm_cv2_out");
    #pragma HLS STREAM variable=strm_cv2_out depth=8192

    static data_t w_cv1[128*128], w_bn1_1[64*9], w_bn1_2[64*9];
    static data_t w_bn2_1[64*9], w_bn2_2[64*9], w_cv2[128*256];
    static acc_t  b_cv1[128], b_bn1_1[64], b_bn1_2[64];
    static acc_t  b_bn2_1[64], b_bn2_2[64], b_cv2[128];

    #pragma HLS DATAFLOW

    read_input(in_stream, strm_input);
    conv1x1_stream(strm_input, strm_cv1_out, w_cv1, b_cv1, 128, 128);

    split_stream_128_to_64x4(
        strm_cv1_out,
        strm_bypass,
        strm_bn1_in,
        strm_bn1_direct,
        strm_bn1_to_add
    );

    conv3x3_stream(strm_bn1_in, strm_bn1_out, w_bn1_1, b_bn1_1, 64);

    // 🌟 1개 스트림을 2개로 분기 복사하는 모듈 연결
    duplicate_stream_64(strm_bn1_out, strm_bn1_out_to_conv, strm_bn1_out_to_concat);

    conv3x3_stream(strm_bn1_out_to_conv, strm_bn2_conv_out, w_bn2_1, b_bn2_1, 64);

    add_stream_64(strm_bn2_conv_out, strm_bn1_to_add, strm_bn2_out);

    concat_stream_64x4_to_256(
        strm_bypass, 
        strm_bn1_direct, 
        strm_bn1_out_to_concat, // 🌟 분기된 전용 스트림 사용
        strm_bn2_out, 
        strm_concat_out
    );

    conv1x1_stream(strm_concat_out, strm_cv2_out, w_cv2, b_cv2, 256, 128);
    write_output(strm_cv2_out, out_stream);
}
