`timescale 1ns / 1ps

module tb_input_buffer;

    // 파라미터 (DUT와 동일하게)
    localparam int IMG_SIZE = 8;
    localparam int DATA_W   = 8;
    localparam int DEPTH    = IMG_SIZE * IMG_SIZE;
    localparam int ADDR_W   = $clog2(DEPTH);

    // 신호 선언
    logic                clk;
    logic                rst_n;
    logic                wr_en;
    logic [ADDR_W-1:0]   wr_addr;
    logic [DATA_W-1:0]   wr_data;
    logic                rd_en;
    logic [ADDR_W-1:0]   rd_addr;
    logic [DATA_W-1:0]   rd_data;

    // DUT (Device Under Test) 연결
    input_buffer #(
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

    // 클럭 생성: 150MHz = 주기 6.667ns → 반주기 3.333ns
    initial clk = 0;
    always #3.333 clk = ~clk;

    // 테스트 시나리오
    initial begin
        // 초기화
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
        // 1단계: 주소 0~7에 값 10, 20, 30... 써넣기
        //--------------------------------------------
        $display("=== 쓰기 시작 ===");
        for (int i = 0; i < 8; i++) begin
            @(posedge clk);
            wr_en   <= 1;
            wr_addr <= i;
            wr_data <= (i + 1) * 10;   // 10, 20, 30, ... 80
            $display("  WRITE addr=%0d data=%0d", i, (i+1)*10);
        end
        @(posedge clk);
        wr_en <= 0;

        //--------------------------------------------
        // 2단계: 다시 읽어서 확인
        //  ★ 주소를 넣은 다음 클럭에 데이터가 나옴
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

    // 읽기 결과 자동 확인 (1클럭 지연 반영)
    logic [ADDR_W-1:0] rd_addr_d;
    logic              rd_en_d;

    always_ff @(posedge clk) begin
        rd_addr_d <= rd_addr;
        rd_en_d   <= rd_en;
    end

    always_ff @(posedge clk) begin
        if (rd_en_d) begin
            if (rd_data == (rd_addr_d + 1) * 10)
                $display("  [OK]   addr=%0d  기대=%0d  실제=%0d",
                          rd_addr_d, (rd_addr_d+1)*10, rd_data);
            else
                $display("  [FAIL] addr=%0d  기대=%0d  실제=%0d",
                          rd_addr_d, (rd_addr_d+1)*10, rd_data);
        end
    end

endmodule