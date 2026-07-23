`timescale 1ns / 1ps
//============================================================
// conv_top.sv
//  - 5개 모듈을 하나로 통합한 3x3 컨볼루션 가속기
//  - 데이터 흐름:
//      input_buffer → window_gen → mac_array → output_buffer
//      (controller가 전체 지휘)
//  - 데이터 타입: INT8 signed 입력, INT32 signed 누적
//============================================================
module conv_top #(
    parameter int IMG_SIZE   = 8,
    parameter int DATA_W     = 8,
    parameter int ACC_W      = 32,
    parameter int DEPTH      = IMG_SIZE * IMG_SIZE,
    parameter int ADDR_W     = $clog2(DEPTH),
    parameter int OUT_SIZE   = IMG_SIZE - 2,
    parameter int OUT_DEPTH  = OUT_SIZE * OUT_SIZE,
    parameter int OUT_ADDR_W = $clog2(OUT_DEPTH)
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // 제어
    input  logic                     start,
    output logic                     busy,
    output logic                     done,

    // 입력 이미지 쓰기 (외부에서 이미지 적재)
    input  logic                     img_wr_en,
    input  logic [ADDR_W-1:0]        img_wr_addr,
    input  logic signed [DATA_W-1:0] img_wr_data,      // ★signed

    // 가중치 입력 (9개, 고정)
    input  logic signed [DATA_W-1:0] weight [0:8],

    // 결과 읽기 (외부에서 결과 회수)
    input  logic                     res_rd_en,
    input  logic [OUT_ADDR_W-1:0]    res_rd_addr,
    output logic signed [ACC_W-1:0]  res_rd_data
);

    //--------------------------------------------------------
    // 내부 연결 신호
    //--------------------------------------------------------
    // controller → input_buffer
    logic                     ib_rd_en;
    logic [ADDR_W-1:0]        ib_rd_addr;

    // input_buffer → window_gen
    logic signed [DATA_W-1:0] ib_rd_data;              // ★signed

    // controller → window_gen
    logic                     wg_in_valid;

    // window_gen → mac_array
    logic signed [DATA_W-1:0] win [0:8];               // ★signed
    logic                     win_valid;

    // mac_array → output_buffer
    logic signed [ACC_W-1:0]  mac_dot;
    logic                     mac_out_valid;

    // controller → output_buffer
    logic                     ob_wr_en;
    logic [OUT_ADDR_W-1:0]    ob_wr_addr;

    //--------------------------------------------------------
    // 1) Controller (지휘자)
    //--------------------------------------------------------
    controller #(
        .IMG_SIZE(IMG_SIZE),
        .PIPE_LAT(7)
    ) u_controller (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .ib_rd_en      (ib_rd_en),
        .ib_rd_addr    (ib_rd_addr),
        .wg_in_valid   (wg_in_valid),
        .mac_out_valid (mac_out_valid),
        .ob_wr_en      (ob_wr_en),
        .ob_wr_addr    (ob_wr_addr),
        .busy          (busy),
        .done          (done)
    );

    //--------------------------------------------------------
    // 2) Input Buffer (이미지 저장소)
    //--------------------------------------------------------
    input_buffer #(
        .IMG_SIZE(IMG_SIZE),
        .DATA_W(DATA_W)
    ) u_input_buffer (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (img_wr_en),
        .wr_addr (img_wr_addr),
        .wr_data (img_wr_data),
        .rd_en   (ib_rd_en),
        .rd_addr (ib_rd_addr),
        .rd_data (ib_rd_data)
    );

    //--------------------------------------------------------
    // 3) Window Generator (3x3 창문 생성)
    //--------------------------------------------------------
    window_gen #(
        .IMG_SIZE(IMG_SIZE),
        .DATA_W(DATA_W)
    ) u_window_gen (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (wg_in_valid),
        .pixel_in  (ib_rd_data),
        .win       (win),
        .win_valid (win_valid)
    );

    //--------------------------------------------------------
    // 4) MAC Array (곱셈 + 덧셈)
    //--------------------------------------------------------
    mac_array #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_mac_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (win_valid),
        .win       (win),
        .weight    (weight),
        .dot       (mac_dot),
        .out_valid (mac_out_valid)
    );

    //--------------------------------------------------------
    // 5) Output Buffer (결과 저장소)
    //--------------------------------------------------------
    output_buffer #(
        .IMG_SIZE(OUT_SIZE),
        .DATA_W(ACC_W)
    ) u_output_buffer (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (ob_wr_en),
        .wr_addr (ob_wr_addr),
        .wr_data (mac_dot),
        .rd_en   (res_rd_en),
        .rd_addr (res_rd_addr),
        .rd_data (res_rd_data)
    );

endmodule