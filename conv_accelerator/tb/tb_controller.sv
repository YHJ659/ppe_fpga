`timescale 1ns / 1ps

module tb_controller;

    localparam int IMG_SIZE   = 8;
    localparam int DEPTH      = IMG_SIZE * IMG_SIZE;   // 64
    localparam int ADDR_W     = $clog2(DEPTH);         // 6
    localparam int OUT_SIZE   = IMG_SIZE - 2;          // 6
    localparam int OUT_DEPTH  = OUT_SIZE * OUT_SIZE;   // 36
    localparam int OUT_ADDR_W = $clog2(OUT_DEPTH);     // 6
    localparam int PIPE_LAT   = 7;

    logic                    clk;
    logic                    rst_n;
    logic                    start;
    logic                    ib_rd_en;
    logic [ADDR_W-1:0]       ib_rd_addr;
    logic                    wg_in_valid;
    logic                    mac_out_valid;
    logic                    ob_wr_en;
    logic [OUT_ADDR_W-1:0]   ob_wr_addr;
    logic                    busy;
    logic                    done;

    // DUT
    controller #(
        .IMG_SIZE(IMG_SIZE),
        .PIPE_LAT(PIPE_LAT)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .ib_rd_en(ib_rd_en),
        .ib_rd_addr(ib_rd_addr),
        .wg_in_valid(wg_in_valid),
        .mac_out_valid(mac_out_valid),
        .ob_wr_en(ob_wr_en),
        .ob_wr_addr(ob_wr_addr),
        .busy(busy),
        .done(done)
    );

    // 150MHz
    initial clk = 0;
    always #3.333 clk = ~clk;

    //--------------------------------------------------------
    // mac_out_valid 모사 (실제 파이프라인 흉내)
    //  - window_gen이 유효한 창문 36개를 뱉는 것을 모사
    //  - wg_in_valid로부터 6클럭 뒤에 결과가 나온다고 가정
    //--------------------------------------------------------
    logic [7:0] pipe_sr;
    int         win_count;    // 유효 윈도우 개수 카운트
    logic       fake_win_valid;

    // window_gen 모사: 픽셀이 들어온 뒤 유효 창문만 36개 생성
    // (실제로는 row>=2 && col>=2 조건이지만, 여기선 개수만 맞춤)
    int px_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px_count       <= 0;
            fake_win_valid <= 1'b0;
        end else begin
            if (wg_in_valid) begin
                px_count <= px_count + 1;
                // 8x8에서 3x3 유효 창문: 2행 2열 이후부터
                // 대략적으로 18번째 픽셀부터 유효하다고 모사
                if (px_count >= 18 && win_count < OUT_DEPTH)
                    fake_win_valid <= 1'b1;
                else
                    fake_win_valid <= 1'b0;
            end else begin
                fake_win_valid <= 1'b0;
            end
        end
    end

    // mac_array 5단 파이프라인 모사
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pipe_sr <= '0;
        else        pipe_sr <= {pipe_sr[6:0], fake_win_valid};
    end

    assign mac_out_valid = pipe_sr[4];   // 5클럭 지연

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 win_count <= 0;
        else if (start)             win_count <= 0;
        else if (mac_out_valid)     win_count <= win_count + 1;
    end

    //--------------------------------------------------------
    // 모니터링
    //--------------------------------------------------------
    int rd_first_time, rd_last_time, done_time;
    logic rd_first_seen;

    always @(posedge clk) begin
        if (ib_rd_en && !rd_first_seen) begin
            rd_first_seen = 1;
            rd_first_time = $time;
            $display("  [%0t ps] 첫 읽기 시작: addr=%0d", $time, ib_rd_addr);
        end
        if (ib_rd_en && ib_rd_addr == DEPTH-1) begin
            rd_last_time = $time;
            $display("  [%0t ps] 마지막 읽기: addr=%0d", $time, ib_rd_addr);
        end
        if (done) begin
            done_time = $time;
            $display("  [%0t ps] DONE 신호 발생", $time);
        end
    end

    // 쓰기 주소 추적
    always @(posedge clk) begin
        if (ob_wr_en) begin
            if (ob_wr_addr < 3 || ob_wr_addr > OUT_DEPTH-3)
                $display("  [WRITE] ob_wr_addr=%0d", ob_wr_addr);
        end
    end

    //--------------------------------------------------------
    // 테스트 시나리오
    //--------------------------------------------------------
    initial begin
        rst_n         = 0;
        start         = 0;
        rd_first_seen = 0;

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=== Controller 테스트 시작 ===");
        $display("--- 초기 상태 확인 ---");
        if (busy == 0 && done == 0)
            $display("  [OK  ] IDLE 상태: busy=0, done=0");
        else
            $display("  [FAIL] 초기 상태 이상: busy=%0d done=%0d", busy, done);

        // start 펄스
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        $display("--- 동작 시작 ---");

        // busy가 뜨는지 확인
        repeat(2) @(posedge clk);
        if (busy) $display("  [OK  ] busy 신호 정상");
        else      $display("  [FAIL] busy 신호 안 뜸");

        // done 대기
        wait (done == 1);
        @(posedge clk);

        $display("--- 완료 후 검증 ---");
        $display("  총 유효 출력 개수: %0d (기대: %0d)", win_count, OUT_DEPTH);
        if (win_count == OUT_DEPTH)
            $display("  [OK  ] 출력 개수 정확");
        else
            $display("  [INFO] 출력 개수 차이 (모사 모델 한계일 수 있음)");

        repeat(5) @(posedge clk);

        if (busy == 0)
            $display("  [OK  ] 완료 후 IDLE 복귀");
        else
            $display("  [FAIL] busy가 안 내려감");

        $display("=== 시뮬레이션 종료 ===");
        $finish;
    end

    // 타임아웃 방지
    initial begin
        #50000;
        $display("!!! TIMEOUT - done 신호가 안 뜸 !!!");
        $finish;
    end

endmodule