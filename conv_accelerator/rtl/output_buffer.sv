`timescale 1ns / 1ps
//============================================================
// output_buffer.sv
//  - MAC Array의 누적 결과를 저장하는 출력 버퍼
//  - BRAM 스타일, 읽기 latency 1클럭
//  - 누적 결과는 음수가 될 수 있으므로 signed (INT32)
//============================================================
module output_buffer #(
    parameter int IMG_SIZE = 8,                     // 출력 피처맵 한 변
    parameter int DATA_W   = 32,                    // 누적 결과 (INT32)
    parameter int DEPTH    = IMG_SIZE * IMG_SIZE,
    parameter int ADDR_W   = $clog2(DEPTH)
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // 쓰기 포트 (MAC Array 결과가 들어옴)
    input  logic                       wr_en,
    input  logic [ADDR_W-1:0]          wr_addr,
    input  logic signed [DATA_W-1:0]   wr_data,      // ★signed

    // 읽기 포트 (PS가 결과를 가져감)
    input  logic                       rd_en,
    input  logic [ADDR_W-1:0]          rd_addr,
    output logic signed [DATA_W-1:0]   rd_data       // ★signed, 1클럭 latency
);

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