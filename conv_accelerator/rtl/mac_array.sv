`timescale 1ns / 1ps
//============================================================
// mac_array.sv
//  - 3x3 윈도우 9개 × 가중치 9개 → 곱하고 전부 더함
//  - Adder Tree를 4단 파이프라인으로 분할 (150MHz 확보 목적)
//  - 총 latency: 5클럭 (곱셈1 + 덧셈4)
//============================================================
module mac_array #(
    parameter int DATA_W = 8,       // 입력/가중치 비트폭 (INT8)
    parameter int ACC_W  = 32       // 누적 결과 비트폭 (INT32)
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     in_valid,
    input  logic signed [DATA_W-1:0] win    [0:8],   // 윈도우 9개
    input  logic signed [DATA_W-1:0] weight [0:8],   // 가중치 9개

    output logic signed [ACC_W-1:0]  dot,            // 최종 결과
    output logic                     out_valid
);

    //--------------------------------------------------------
    // Stage 0: 곱셈 9개 (병렬, DSP48로 매핑됨)
    //--------------------------------------------------------
    logic signed [2*DATA_W-1:0] prod [0:8];   // 8x8 = 16비트

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 9; i++) prod[i] <= '0;
        end
        else if (in_valid) begin
            for (int i = 0; i < 9; i++)
                prod[i] <= win[i] * weight[i];
        end
    end

    //--------------------------------------------------------
    // Stage 1: 4쌍 덧셈 (병렬) + prod[8] 보관
    //--------------------------------------------------------
    logic signed [ACC_W-1:0] s1 [0:3];
    logic signed [ACC_W-1:0] p8_d1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) s1[i] <= '0;
            p8_d1 <= '0;
        end
        else begin
            s1[0] <= prod[0] + prod[1];
            s1[1] <= prod[2] + prod[3];
            s1[2] <= prod[4] + prod[5];
            s1[3] <= prod[6] + prod[7];
            p8_d1 <= prod[8];              // 짝이 없어서 그냥 넘김
        end
    end

    //--------------------------------------------------------
    // Stage 2: 2쌍 덧셈
    //--------------------------------------------------------
    logic signed [ACC_W-1:0] s2 [0:1];
    logic signed [ACC_W-1:0] p8_d2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2[0] <= '0;  s2[1] <= '0;  p8_d2 <= '0;
        end
        else begin
            s2[0] <= s1[0] + s1[1];
            s2[1] <= s1[2] + s1[3];
            p8_d2 <= p8_d1;
        end
    end

    //--------------------------------------------------------
    // Stage 3: 1쌍 덧셈
    //--------------------------------------------------------
    logic signed [ACC_W-1:0] s3;
    logic signed [ACC_W-1:0] p8_d3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3 <= '0;  p8_d3 <= '0;
        end
        else begin
            s3    <= s2[0] + s2[1];
            p8_d3 <= p8_d2;
        end
    end

    //--------------------------------------------------------
    // Stage 4: 마지막 하나(prod[8]) 합류 → 최종 결과
    //--------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dot <= '0;
        else        dot <= s3 + p8_d3;
    end

    //--------------------------------------------------------
    // valid 신호를 파이프라인 깊이만큼 지연 (5단)
    //  → 데이터와 valid가 같이 도착하게
    //--------------------------------------------------------
    logic [4:0] valid_sr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_sr <= '0;
        else        valid_sr <= {valid_sr[3:0], in_valid};
    end

    assign out_valid = valid_sr[4];

endmodule