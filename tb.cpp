#include <iostream>
#include "model6_c2f.h"

int main() {
    // AXI-Stream 선언
    hls::stream<axis_t> in_stream("input_stream");
    hls::stream<axis_t> out_stream("output_stream");

    // 모델 6의 입력/출력 텐서 크기 계산
    // 128채널 * 40 * 40 피처맵 = 204,800 bytes
    int total_pixels = 128 * FEAT_SIZE * FEAT_SIZE; 
    
    // 64비트 버스(8바이트)로 한 번에 전송하므로 패킷 수는 / 8
    int num_packets = total_pixels / 8;

    std::cout << "===========================================" << std::endl;
    std::cout << " YOLOv8n model.6 (C2f) HLS Testbench Start " << std::endl;
    std::cout << "===========================================" << std::endl;
    std::cout << "Expected Packets (64-bit): " << num_packets << std::endl;

    // --------------------------------------------------------
    // [Step 1] 입력 더미 데이터 생성 및 스트림 주입
    // --------------------------------------------------------
    std::cout << "[1] Generating Input Stream Data..." << std::endl;
    for (int i = 0; i < num_packets; i++) {
        axis_t pkt;
        pkt.keep = -1; // 0xFF (모든 바이트 유효)
        pkt.strb = -1;
        pkt.user = 0;
        pkt.id = 0;
        pkt.dest = 0;

        // 8개의 임의의 INT8 데이터를 64비트 패킷 하나에 패킹
        for (int j = 0; j < 8; j++) {
            data_t dummy_val = (i * 8 + j) % 128; // 0~127 사이의 더미 값
            pkt.data(j*8 + 7, j*8) = dummy_val;
        }

        // 마지막 패킷에 TLAST 신호(1) 삽입
        if (i == num_packets - 1) pkt.last = 1;
        else pkt.last = 0;

        in_stream.write(pkt);
    }

    // --------------------------------------------------------
    // [Step 2] DUT (Device Under Test) 실행
    // --------------------------------------------------------
    std::cout << "[2] Running C2f Accelerator..." << std::endl;
    model6_c2f_accel(in_stream, out_stream);
    std::cout << "[2] Accelerator Execution Completed." << std::endl;

    // --------------------------------------------------------
    // [Step 3] 출력 스트림 검증
    // --------------------------------------------------------
    std::cout << "[3] Checking Output Stream Data..." << std::endl;
    int out_packet_cnt = 0;
    bool last_flag_received = false;

    while (!out_stream.empty()) {
        axis_t out_pkt = out_stream.read();
        
        // 마지막 패킷 확인
        if (out_pkt.last == 1) {
            last_flag_received = true;
        }
        
        // (선택) 첫 번째 패킷의 언패킹 값 확인
        if (out_packet_cnt == 0) {
            std::cout << "    -> First Packet Output Sample: ";
            for(int j=0; j<8; j++){
                std::cout << (int)out_pkt.data(j*8 + 7, j*8) << " ";
            }
            std::cout << std::endl;
        }
        out_packet_cnt++;
    }

    // --------------------------------------------------------
    // [Step 4] 테스트 결과 판정 (Pass / Fail)
    // --------------------------------------------------------
    if (out_packet_cnt != num_packets) {
        std::cout << "[FAIL] Packet count mismatch! Expected: " << num_packets 
                  << ", Got: " << out_packet_cnt << std::endl;
        return 1; // 0이 아닌 값을 반환하면 Vitis HLS에서 Fail로 처리됨
    }

    if (!last_flag_received) {
        std::cout << "[FAIL] TLAST signal was not received on the output stream!" << std::endl;
        return 1;
    }

    std::cout << "[SUCCESS] HLS C-Simulation Passed! (Stream IN/OUT match)" << std::endl;
    return 0; // Return 0은 C-Simulation 통과를 의미함
}