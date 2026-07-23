`timescale 1ns / 1ps

module tb_conv_top;

    localparam int IMG_SIZE   = 8;
    localparam int DATA_W     = 8;
    localparam int ACC_W      = 32;
    localparam int DEPTH      = IMG_SIZE * IMG_SIZE;   // 64
    localparam int ADDR_W     = $clog2(DEPTH);         // 6
    localparam int OUT_SIZE   = IMG_SIZE - 2;          // 6
    localparam int OUT_DEPTH  = OUT_SIZE * OUT_SIZE;   // 36
    localparam int OUT_ADDR_W = $clog2(OUT_DEPTH);     // 6

    logic                     clk;
    logic                     rst_n;
    logic                     start;
    logic                     busy;
    logic                     done;
    logic                     img_wr_en;
    logic [ADDR_W-1:0]        img_wr_addr;
    logic [DATA_W-1:0]        img_wr_data;
    logic signed [DATA_W-1:0] weight [0:8];
    logic                     res_rd_en;
    logic [OUT_ADDR_W-1:0]    res_rd_addr;
    logic signed [ACC_W-1:0]  res_rd_data;

    // DUT
    conv_top #(
        .IMG_SIZE(IMG_SIZE),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .busy        (busy),
        .done        (done),
        .img_wr_en   (img_wr_en),
        .img_wr_addr (img_wr_addr),
        .img_wr_data (img_wr_data),
        .weight      (weight),
        .res_rd_en   (res_rd_en),
        .res_rd_addr (res_rd_addr),
        .res_rd_data (res_rd_data)
    );

    // 150MHz
    initial clk = 0;
    always #3.333 clk = ~clk;

    //--------------------------------------------------------
    // 골든 모델: 소프트웨어로 conv 계산
    //--------------------------------------------------------
    logic signed [DATA_W-1:0] image  [0:DEPTH-1];      // 입력 이미지
    logic signed [ACC_W-1:0]  golden [0:OUT_DEPTH-1];  // 기대 결과

    task automatic compute_golden();
        int idx;
        logic signed [ACC_W-1:0] sum;
        idx = 0;
        // 3x3 창문을 (0,0)부터 (5,5)까지 슬라이딩
        for (int r = 0; r < OUT_SIZE; r++) begin
            for (int c = 0; c < OUT_SIZE; c++) begin
                sum = 0;
                for (int kr = 0; kr < 3; kr++) begin
                    for (int kc = 0; kc < 3; kc++) begin
                        sum = sum + image[(r+kr)*IMG_SIZE + (c+kc)]
                                  * weight[kr*3 + kc];
                    end
                end
                golden[idx] = sum;
                idx++;
            end
        end
    endtask

    //--------------------------------------------------------
    // 테스트 시나리오
    //--------------------------------------------------------
    int pass_cnt, fail_cnt;

    initial begin
        rst_n       = 0;
        start       = 0;
        img_wr_en   = 0;
        img_wr_addr = 0;
        img_wr_data = 0;
        res_rd_en   = 0;
        res_rd_addr = 0;
        pass_cnt    = 0;
        fail_cnt    = 0;
        for (int i = 0; i < 9; i++) weight[i] = 0;

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("========================================");
        $display("=== conv_top 통합 테스트 ===");
        $display("========================================");

        //====================================================
        // TEST 1: 순번 이미지 + 전부 1인 필터
        //====================================================
        $display("\n--- TEST 1: 순번 이미지, 필터 all-1 ---");

        // 이미지 준비: 0, 1, 2, ... 63
        for (int i = 0; i < DEPTH; i++) image[i] = i;
        // 필터: 전부 1 (즉, 3x3 합계를 구하는 필터)
        for (int i = 0; i < 9; i++) weight[i] = 1;

        run_one_test("TEST1");

        //====================================================
        // TEST 2: Sobel 필터 (세로 엣지 검출)
        //====================================================
        $display("\n--- TEST 2: 순번 이미지, Sobel 필터 ---");

        for (int i = 0; i < DEPTH; i++) image[i] = i;
        weight = '{-1, 0, 1,
                   -2, 0, 2,
                   -1, 0, 1};

        run_one_test("TEST2");

        //====================================================
        // TEST 3: 랜덤 이미지 + 랜덤 필터
        //====================================================
        $display("\n--- TEST 3: 랜덤 이미지, 랜덤 필터 ---");

        for (int i = 0; i < DEPTH; i++)
            image[i] = $urandom_range(0, 127);
        for (int i = 0; i < 9; i++)
            weight[i] = $urandom_range(0, 20) - 10;   // -10 ~ +10

        run_one_test("TEST3");

        //====================================================
        // 최종 결과
        //====================================================
        $display("\n========================================");
        $display("=== 최종 결과: PASS=%0d, FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("=== 전체 통과! 골든모델과 완전 일치 ===");
        else
            $display("=== 불일치 발생 ===");
        $display("========================================");
        $finish;
    end

    //--------------------------------------------------------
    // 테스트 1회 실행 태스크
    //--------------------------------------------------------
    task automatic run_one_test(input string tname);
        int local_pass, local_fail;
        local_pass = 0;
        local_fail = 0;

        // 골든 모델 계산
        compute_golden();

        // 1) 이미지를 input_buffer에 적재
        for (int i = 0; i < DEPTH; i++) begin
            @(posedge clk);
            img_wr_en   <= 1;
            img_wr_addr <= i;
            img_wr_data <= image[i];
        end
        @(posedge clk);
        img_wr_en <= 0;

        // 2) start 펄스
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // 3) done 대기
        wait (done == 1);
        @(posedge clk);
        $display("  연산 완료. 결과 검증 시작...");

        // 4) 결과 읽어서 골든모델과 비교
        for (int i = 0; i < OUT_DEPTH; i++) begin
            @(posedge clk);
            res_rd_en   <= 1;
            res_rd_addr <= i;
            @(posedge clk);          // BRAM 1클럭 대기
            res_rd_en   <= 0;
            @(negedge clk);          // 데이터 안정화

            if (res_rd_data == golden[i]) begin
                local_pass++;
            end else begin
                local_fail++;
                if (local_fail <= 5)   // 처음 5개만 출력
                    $display("  [FAIL] idx=%0d  기대=%0d  실제=%0d",
                              i, golden[i], res_rd_data);
            end
        end

        $display("  %s 결과: PASS=%0d / %0d", tname, local_pass, OUT_DEPTH);
        if (local_fail == 0) $display("  [OK] %s 전부 일치!", tname);

        pass_cnt += local_pass;
        fail_cnt += local_fail;

        repeat(5) @(posedge clk);
    endtask

    // 타임아웃
    initial begin
        #200000;
        $display("!!! TIMEOUT !!!");
        $finish;
    end

endmodule