`timescale 1ns / 1ps
//============================================================
// input_buffer.sv
//  - CNN 가속기의 입력 피처맵 저장용 버퍼
//  - BRAM 스타일 (합성 시 Block RAM으로 매핑됨)
//  - INT8 양자화 데이터이므로 signed 처리 (-128 ~ +127)
//  - 목표 클럭: 150MHz (6.667ns)
//
//  [핵심 특성] BRAM은 주소를 넣은 "다음 클럭"에 데이터가 나온다.
//              (읽기 latency = 1 클럭). FSM이 반드시 이걸 반영해야 함.
//============================================================
module input_buffer #(
    parameter int IMG_SIZE = 8,                     // 이미지 한 변 (8x8)
    parameter int DATA_W   = 8,                     // 픽셀 비트폭 (INT8)
    parameter int DEPTH    = IMG_SIZE * IMG_SIZE,   // 전체 픽셀 수 (64)
    parameter int ADDR_W   = $clog2(DEPTH)          // 주소 비트폭 (6)
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // 쓰기 포트 (PS가 이미지를 넣을 때)
    input  logic                       wr_en,
    input  logic [ADDR_W-1:0]          wr_addr,
    input  logic signed [DATA_W-1:0]   wr_data,      // ★signed

    // 읽기 포트 (Window Generator가 읽어갈 때)
    input  logic                       rd_en,
    input  logic [ADDR_W-1:0]          rd_addr,
    output logic signed [DATA_W-1:0]   rd_data       // ★signed, 1클럭 latency
);

    // 실제 메모리 (합성 시 BRAM으로 추론됨)
    logic signed [DATA_W-1:0] mem [0:DEPTH-1];       // ★signed

    // 쓰기
    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // 읽기 (레지스터 출력 → 1클럭 latency)
    always_ff @(posedge clk) begin
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule