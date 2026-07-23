`timescale 1ns / 1ps

module tb_output_buffer;

    localparam int IMG_SIZE = 8;
    localparam int DATA_W   = 32;
    localparam int DEPTH    = IMG_SIZE * IMG_SIZE;
    localparam int ADDR_W   = $clog2(DEPTH);

    logic                clk;
    logic                rst_n;
    logic                wr_en;
    logic [ADDR_W-1:0]   wr_addr;
    logic [DATA_W-1:0]   wr_data;
    logic                rd_en;
    logic [ADDR_W-1:0]   rd_addr;
    logic [DATA_W-1:0]   rd_data;

    // DUT
    output_buffer #(
        .IMG_SIZE(IMG_SIZE),
        .DATA_W(DATA_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    // 150MHz 클럭 (주기 6.667ns)
    initial clk = 0;
    always #3.333 clk = ~clk;

    // 기대값 계산 함수 (쓰기/검증에서 동일하게 사용)
    function automatic logic signed [DATA_W-1:0] expected_val(input int idx);
        // 큰 값 + 음수 섞어서 32비트/부호 확인
        expected_val = (idx % 2 == 0) ?  (32'd100000 * (idx + 1))
                                      : -(32'd100000 * (idx + 1));
    endfunction

    initial begin
        rst_n   = 0;
        wr_en   = 0;
        wr_addr = 0;
        wr_data = 0;
        rd_en   = 0;
        rd_addr = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        //--------------------------------------------
        // 1단계: 큰 값 + 음수를 번갈아 써넣기
        //--------------------------------------------
        $display("=== 쓰기 시작 ===");
        for (int i = 0; i < 8; i++) begin
            @(posedge clk);
            wr_en   <= 1;
            wr_addr <= i;
            wr_data <= expected_val(i);
            $display("  WRITE addr=%0d data=%0d", i, expected_val(i));
        end
        @(posedge clk);
        wr_en <= 0;

        //--------------------------------------------
        // 2단계: 읽기 (1클럭 뒤 데이터 나옴)
        //--------------------------------------------
        $display("=== 읽기 시작 ===");
        for (int i = 0; i < 8; i++) begin
            @(posedge clk);
            rd_en   <= 1;
            rd_addr <= i;
        end
        @(posedge clk);
        rd_en <= 0;

        repeat(5) @(posedge clk);
        $display("=== 시뮬레이션 종료 ===");
        $finish;
    end

    // 1클럭 지연 반영해서 자동 검증
    logic [ADDR_W-1:0] rd_addr_d;
    logic              rd_en_d;

    always_ff @(posedge clk) begin
        rd_addr_d <= rd_addr;
        rd_en_d   <= rd_en;
    end

    always_ff @(posedge clk) begin
        if (rd_en_d) begin
            if ($signed(rd_data) == expected_val(rd_addr_d))
                $display("  [OK]   addr=%0d  기대=%0d  실제=%0d",
                          rd_addr_d, expected_val(rd_addr_d), $signed(rd_data));
            else
                $display("  [FAIL] addr=%0d  기대=%0d  실제=%0d",
                          rd_addr_d, expected_val(rd_addr_d), $signed(rd_data));
        end
    end

endmodule