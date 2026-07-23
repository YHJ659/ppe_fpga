`timescale 1ns / 1ps

module tb_mac_array;

    localparam int DATA_W = 8;
    localparam int ACC_W  = 32;

    logic                     clk;
    logic                     rst_n;
    logic                     in_valid;
    logic signed [DATA_W-1:0] win    [0:8];
    logic signed [DATA_W-1:0] weight [0:8];
    logic signed [ACC_W-1:0]  dot;
    logic                     out_valid;

    // DUT
    mac_array #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .win(win),
        .weight(weight),
        .dot(dot),
        .out_valid(out_valid)
    );

    // 150MHz (주기 6.667ns)
    initial clk = 0;
    always #3.333 clk = ~clk;

    //--------------------------------------------------------
    // 기대값 큐 (동적 큐 - 자동 FIFO)
    //--------------------------------------------------------
    logic signed [ACC_W-1:0] exp_queue [$];
    int pass_cnt;
    int fail_cnt;

    // 기대값 계산 함수
    function automatic logic signed [ACC_W-1:0] calc_expected(
        input logic signed [DATA_W-1:0] w [0:8],
        input logic signed [DATA_W-1:0] p [0:8]
    );
        logic signed [ACC_W-1:0] sum;
        sum = 0;
        for (int i = 0; i < 9; i++)
            sum = sum + (p[i] * w[i]);
        return sum;
    endfunction

    // 자극 인가 태스크
    task automatic drive(
        input logic signed [DATA_W-1:0] p [0:8],
        input logic signed [DATA_W-1:0] w [0:8],
        input string name
    );
        logic signed [ACC_W-1:0] exp;
        @(posedge clk);
        for (int i = 0; i < 9; i++) begin
            win[i]    <= p[i];
            weight[i] <= w[i];
        end
        in_valid <= 1;
        exp = calc_expected(w, p);
        $display("  [IN ] %s : 기대값=%0d", name, exp);
        exp_queue.push_back(exp);
    endtask

    //--------------------------------------------------------
    // 테스트 시나리오
    //--------------------------------------------------------
    logic signed [DATA_W-1:0] tp [0:8];
    logic signed [DATA_W-1:0] tw [0:8];

    initial begin
        rst_n    = 0;
        in_valid = 0;
        pass_cnt = 0;
        fail_cnt = 0;
        for (int i = 0; i < 9; i++) begin
            win[i]    = 0;
            weight[i] = 0;
        end

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=== MAC Array 테스트 시작 ===");

        // TEST1: 모두 1 x 모두 1 → 9
        for (int i = 0; i < 9; i++) begin tp[i] = 1; tw[i] = 1; end
        drive(tp, tw, "TEST1 (all 1x1)");

        // TEST2: 1~9 x 모두 1 → 45
        for (int i = 0; i < 9; i++) begin tp[i] = i+1; tw[i] = 1; end
        drive(tp, tw, "TEST2 (1..9 x 1)");

        // TEST3: 음수 섞기 → 5
        tp = '{1, -2, 3, -4, 5, -6, 7, -8, 9};
        tw = '{1,  1, 1,  1, 1,  1, 1,  1, 1};
        drive(tp, tw, "TEST3 (음수 섞임)");

        // TEST4: 최댓값 127x127x9 → 145161
        for (int i = 0; i < 9; i++) begin tp[i] = 127; tw[i] = 127; end
        drive(tp, tw, "TEST4 (127x127 최대)");

        // TEST5: 최솟값 -128x-128x9 → 147456 (부호 처리 검증)
        for (int i = 0; i < 9; i++) begin tp[i] = -128; tw[i] = -128; end
        drive(tp, tw, "TEST5 (-128x-128 최소)");

        // TEST6: Sobel 필터 → 80
        tp = '{10, 20, 30, 40, 50, 60, 70, 80, 90};
        tw = '{-1,  0,  1, -2,  0,  2, -1,  0,  1};
        drive(tp, tw, "TEST6 (Sobel 필터)");

        @(posedge clk);
        in_valid <= 0;

        repeat(10) @(posedge clk);

        $display("=== 결과: PASS=%0d, FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0 && pass_cnt == 6)
            $display("=== 전체 통과! ===");
        else
            $display("=== 확인 필요 ===");
        $finish;
    end

    //--------------------------------------------------------
    // 출력 자동 검증
    //--------------------------------------------------------
    logic signed [ACC_W-1:0] exp_out;

    always @(posedge clk) begin
        if (out_valid) begin
            if (exp_queue.size() > 0) begin
                exp_out = exp_queue.pop_front();
                if (dot == exp_out) begin
                    pass_cnt++;
                    $display("  [OK  ] 기대=%0d  실제=%0d", exp_out, dot);
                end else begin
                    fail_cnt++;
                    $display("  [FAIL] 기대=%0d  실제=%0d", exp_out, dot);
                end
            end
        end
    end

endmodule