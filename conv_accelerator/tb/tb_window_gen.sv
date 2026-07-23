`timescale 1ns / 1ps

module tb_window_gen;

    localparam int IMG_SIZE = 8;
    localparam int DATA_W   = 8;

    logic                clk;
    logic                rst_n;
    logic                in_valid;
    logic [DATA_W-1:0]   pixel_in;
    logic [DATA_W-1:0]   win [0:8];
    logic                win_valid;

    // DUT
    window_gen #(
        .IMG_SIZE(IMG_SIZE),
        .DATA_W(DATA_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .pixel_in(pixel_in),
        .win(win),
        .win_valid(win_valid)
    );

    // 150MHz
    initial clk = 0;
    always #3.333 clk = ~clk;

    //--------------------------------------------------------
    // 픽셀 스트림 입력: 0, 1, 2, ... 63
    //  → 값이 곧 인덱스라서 파형에서 위치 확인이 쉬움
    //--------------------------------------------------------
    initial begin
        rst_n    = 0;
        in_valid = 0;
        pixel_in = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=== 픽셀 입력 시작 (0~63) ===");
        for (int i = 0; i < IMG_SIZE*IMG_SIZE; i++) begin
            @(posedge clk);
            in_valid <= 1;
            pixel_in <= i[DATA_W-1:0];
        end
        @(posedge clk);
        in_valid <= 0;

        repeat(5) @(posedge clk);
        $display("=== 시뮬레이션 종료 ===");
        $finish;
    end

    //--------------------------------------------------------
    // win_valid가 뜰 때마다 3x3 창문 내용 출력
    //--------------------------------------------------------
    always_ff @(posedge clk) begin
        if (win_valid) begin
            $display("  WINDOW: [%3d %3d %3d]", win[0], win[1], win[2]);
            $display("          [%3d %3d %3d]", win[3], win[4], win[5]);
            $display("          [%3d %3d %3d]", win[6], win[7], win[8]);
            $display("          ----------------");
        end
    end

endmodule