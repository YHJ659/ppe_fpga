`timescale 1ns / 1ps
//============================================================
// window_gen.sv
//  - 픽셀 스트림(1개씩) → 3x3 윈도우(9개 동시 출력)
//  - 라인 버퍼 2줄로 이전 행들을 보관
//  - 목표 클럭 150MHz (조합논리 얕음, 여유)
//  - INT8 양자화 데이터이므로 signed 처리 (-128 ~ +127)
//============================================================
module window_gen #(
    parameter int IMG_SIZE = 8,     // 이미지 한 변
    parameter int DATA_W   = 8      // 픽셀 비트폭
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       in_valid,     // 픽셀 입력 유효
    input  logic signed [DATA_W-1:0]   pixel_in,     // ★signed
    output logic signed [DATA_W-1:0]   win [0:8],    // ★signed
    output logic                       win_valid     // 윈도우 유효
);

    //--------------------------------------------------------
    // 1) 라인 버퍼 2줄 (이전 2개 행 저장)
    //--------------------------------------------------------
    logic signed [DATA_W-1:0] line_buf0 [0:IMG_SIZE-1];  // ★signed, 1행 전
    logic signed [DATA_W-1:0] line_buf1 [0:IMG_SIZE-1];  // ★signed, 2행 전

    // 열 위치 카운터 (지금 몇 번째 칸인가)
    logic [$clog2(IMG_SIZE)-1:0] col_cnt;
    // 행 위치 카운터 (지금 몇 번째 줄인가)
    logic [$clog2(IMG_SIZE)-1:0] row_cnt;

    //--------------------------------------------------------
    // 2) 3x3 윈도우용 시프트 레지스터
    //    각 행마다 3개씩 (가로로 밀림)
    //--------------------------------------------------------
    logic signed [DATA_W-1:0] sr0 [0:2];   // ★signed, 2행 전 (윈도우 맨 위)
    logic signed [DATA_W-1:0] sr1 [0:2];   // ★signed, 1행 전 (윈도우 가운데)
    logic signed [DATA_W-1:0] sr2 [0:2];   // ★signed, 현재 행 (윈도우 맨 아래)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= '0;
            row_cnt <= '0;
            for (int i = 0; i < 3; i++) begin
                sr0[i] <= '0;
                sr1[i] <= '0;
                sr2[i] <= '0;
            end
        end
        else if (in_valid) begin
            //---- 시프트 레지스터: 왼쪽으로 한 칸씩 밀기 ----
            sr0[0] <= sr0[1];  sr0[1] <= sr0[2];  sr0[2] <= line_buf1[col_cnt];
            sr1[0] <= sr1[1];  sr1[1] <= sr1[2];  sr1[2] <= line_buf0[col_cnt];
            sr2[0] <= sr2[1];  sr2[1] <= sr2[2];  sr2[2] <= pixel_in;

            //---- 라인 버퍼 갱신 ----
            // 현재 픽셀은 line_buf0에, line_buf0의 옛 값은 line_buf1로
            line_buf1[col_cnt] <= line_buf0[col_cnt];
            line_buf0[col_cnt] <= pixel_in;

            //---- 위치 카운터 ----
            if (col_cnt == IMG_SIZE-1) begin
                col_cnt <= '0;
                row_cnt <= row_cnt + 1;
            end else begin
                col_cnt <= col_cnt + 1;
            end
        end
    end

    //--------------------------------------------------------
    // 3) 윈도우 출력 (조합)
    //--------------------------------------------------------
    always_comb begin
        win[0] = sr0[0];  win[1] = sr0[1];  win[2] = sr0[2];
        win[3] = sr1[0];  win[4] = sr1[1];  win[5] = sr1[2];
        win[6] = sr2[0];  win[7] = sr2[1];  win[8] = sr2[2];
    end

    //--------------------------------------------------------
    // 4) valid 신호
    //    3행 이상 채워지고(row>=2), 3열 이상 진행됐을 때만 유효
    //    (초반엔 라인버퍼가 안 채워져서 쓰레기값)
    //--------------------------------------------------------
    logic win_valid_pre;
    always_comb begin
        win_valid_pre = in_valid && (row_cnt >= 2) && (col_cnt >= 2);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) win_valid <= 1'b0;
        else        win_valid <= win_valid_pre;
    end

endmodule