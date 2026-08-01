#include <ap_int.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>
#include "model6_c2f.h"

typedef ap_int<8> data_t;    
typedef ap_int<32> acc_t;    
typedef ap_axis<64, 0, 0, 0> axis_t; 

// --------------------------------------------------------
// INT8 SiLU LUT (256 entries)
// --------------------------------------------------------
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
// Dataflow 전용 Input / Output Unpack & Pack
// --------------------------------------------------------
void read_input(hls::stream<axis_t> &in_stream, hls::stream<data_t> &strm_input) {
    int total_packets = (128 * FEAT_SIZE * FEAT_SIZE) / 8;
    for (int i = 0; i < total_packets; i++) {
        #pragma HLS PIPELINE II=1
        axis_t pkt = in_stream.read();
        for (int j = 0; j < 8; j++) {
            #pragma HLS UNROLL
            strm_input.write((data_t)((pkt.data >> (j * 8)) & 0xFF));
        }
    }
}

void write_output(hls::stream<data_t> &strm_cv2_out, hls::stream<axis_t> &out_stream) {
    int total_packets = (128 * FEAT_SIZE * FEAT_SIZE) / 8;
    for (int i = 0; i < total_packets; i++) {
        #pragma HLS PIPELINE II=1
        axis_t pkt;
        pkt.keep = -1; pkt.strb = -1; pkt.user = 0; pkt.id = 0; pkt.dest = 0;
        
        ap_uint<64> packed_data = 0;
        for (int j = 0; j < 8; j++) {
            #pragma HLS UNROLL
            ap_uint<8> val = strm_cv2_out.read();
            packed_data |= ((ap_uint<64>)val << (j * 8));
        }
        pkt.data = packed_data;
        pkt.last = (i == total_packets - 1) ? 1 : 0;
        
        out_stream.write(pkt);
    }
}

// --------------------------------------------------------
// Stream 1x1 Conv
// --------------------------------------------------------
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

// --------------------------------------------------------
// Stream 3x3 Conv (LineBuffer 지연 보정 추가)
// --------------------------------------------------------
void conv3x3_stream(
    hls::stream<data_t> &in_strm, 
    hls::stream<data_t> &out_strm, 
    const data_t weight[], 
    const acc_t bias[], 
    int ch
) {
    static data_t line_buf[64][2][FEAT_SIZE];
    #pragma HLS ARRAY_PARTITION variable=line_buf dim=1 complete
    #pragma HLS ARRAY_PARTITION variable=line_buf dim=2 complete

    static data_t window[64][3][3];
    #pragma HLS ARRAY_PARTITION variable=window dim=1 complete
    #pragma HLS ARRAY_PARTITION variable=window dim=2 complete
    #pragma HLS ARRAY_PARTITION variable=window dim=3 complete

    for (int h = 0; h < FEAT_SIZE; h++) {
        for (int w = 0; w < FEAT_SIZE; w++) {
            for (int c = 0; c < ch; c++) {
                #pragma HLS PIPELINE II=1

                data_t in_pixel = in_strm.read();

                // Shift Window
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

                // MAC 연산
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

// --------------------------------------------------------
// Channel Split (1픽셀 단위 분기)
// --------------------------------------------------------
void split_stream_128_to_64x4(
    hls::stream<data_t> &in_strm,
    hls::stream<data_t> &out_bypass,
    hls::stream<data_t> &out_bn_to_conv,
    hls::stream<data_t> &out_bn_to_concat,
    hls::stream<data_t> &out_bn_to_add
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        // 1. Bypass 64채널
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_bypass.write(in_strm.read());
        }
        // 2. Bottleneck 64채널 (3개 모듈로 복사 분기)
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            data_t val = in_strm.read();
            out_bn_to_conv.write(val);
            out_bn_to_concat.write(val);
            out_bn_to_add.write(val);
        }
    }
}

// --------------------------------------------------------
// Concat (각 스트림별로 64개씩 1픽셀분 데이터 읽기)
// --------------------------------------------------------
void concat_stream_64x4_to_256(
    hls::stream<data_t> &strm0,
    hls::stream<data_t> &strm1,
    hls::stream<data_t> &strm2,
    hls::stream<data_t> &strm3,
    hls::stream<data_t> &out_concat
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        // [Stream 0: Bypass 64개]
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm0.read());
        }
        // [Stream 1: Direct 64개]
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm1.read());
        }
        // [Stream 2: BN1 Out 64개]
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm2.read());
        }
        // [Stream 3: BN2 Out 64개]
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_concat.write(strm3.read());
        }
    }
}

// --------------------------------------------------------
// Shortcut 덧셈 전용 모듈
// --------------------------------------------------------
void add_stream_64(
    hls::stream<data_t> &in1,
    hls::stream<data_t> &in2,
    hls::stream<data_t> &out_strm
) {
    for (int hw = 0; hw < FEAT_SIZE * FEAT_SIZE; hw++) {
        for (int c = 0; c < 64; c++) {
            #pragma HLS PIPELINE II=1
            out_strm.write(in1.read() + in2.read());
        }
    }
}

// --------------------------------------------------------
// Top Module (model6_c2f_accel)
// --------------------------------------------------------
void model6_c2f_accel(
    hls::stream<axis_t> &in_stream,
    hls::stream<axis_t> &out_stream
) {
    #pragma HLS INTERFACE axis port=in_stream
    #pragma HLS INTERFACE axis port=out_stream
    #pragma HLS INTERFACE s_axilite port=return bundle=CTRL_BUS

    // 🌟 핵심: Direct/Bypass FIFO Depth를 대폭 확장하여 Dataflow Stall 방지
    hls::stream<data_t> strm_input("strm_input");
    #pragma HLS STREAM variable=strm_input depth=2048

    hls::stream<data_t> strm_cv1_out("strm_cv1_out");
    #pragma HLS STREAM variable=strm_cv1_out depth=2048

    hls::stream<data_t> strm_bypass("strm_bypass");
    #pragma HLS STREAM variable=strm_bypass depth=65536

    hls::stream<data_t> strm_bn1_direct("strm_bn1_direct");
    #pragma HLS STREAM variable=strm_bn1_direct depth=65536

    hls::stream<data_t> strm_bn1_to_add("strm_bn1_to_add");
    #pragma HLS STREAM variable=strm_bn1_to_add depth=65536

    // Conv 경로 스트림
    hls::stream<data_t> strm_bn1_in("strm_bn1_in");
    #pragma HLS STREAM variable=strm_bn1_in depth=8192

    hls::stream<data_t> strm_bn1_out("strm_bn1_out");
    #pragma HLS STREAM variable=strm_bn1_out depth=8192

    hls::stream<data_t> strm_bn2_conv_out("strm_bn2_conv_out");
    #pragma HLS STREAM variable=strm_bn2_conv_out depth=8192

    hls::stream<data_t> strm_bn2_out("strm_bn2_out");
    #pragma HLS STREAM variable=strm_bn2_out depth=8192

    // 후단 스트림
    hls::stream<data_t> strm_concat_out("strm_concat_out");
    #pragma HLS STREAM variable=strm_concat_out depth=4096

    hls::stream<data_t> strm_cv2_out("strm_cv2_out");
    #pragma HLS STREAM variable=strm_cv2_out depth=4096

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
    conv3x3_stream(strm_bn1_out, strm_bn2_conv_out, w_bn2_1, b_bn2_1, 64);

    add_stream_64(strm_bn2_conv_out, strm_bn1_to_add, strm_bn2_out);

    concat_stream_64x4_to_256(strm_bypass, strm_bn1_direct, strm_bn1_out, strm_bn2_out, strm_concat_out);

    conv1x1_stream(strm_concat_out, strm_cv2_out, w_cv2, b_cv2, 256, 128);
    write_output(strm_cv2_out, out_stream);
}