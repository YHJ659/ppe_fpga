`timescale 1ns/1ps

module tb_mac_array_scoreboard;
    localparam integer DATA_W = 8;
    localparam integer ACC_W = 32;
    localparam integer MAX_CASES = 64;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic in_valid = 1'b0;
    logic signed [DATA_W-1:0] win [0:8];
    logic signed [DATA_W-1:0] weight [0:8];
    logic signed [ACC_W-1:0] dot;
    logic out_valid;

    logic signed [ACC_W-1:0] expected [0:MAX_CASES-1];
    integer pushed;
    integer popped;
    integer errors;
    integer i;

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

    always #5 clk = ~clk;

    function automatic signed [ACC_W-1:0] calculate_dot;
        integer lane;
        reg signed [ACC_W-1:0] sum;
        begin
            sum = 0;
            for (lane = 0; lane < 9; lane = lane + 1)
                sum = sum + ($signed(win[lane]) * $signed(weight[lane]));
            calculate_dot = sum;
        end
    endfunction

    task automatic accept_current;
        begin
            if (pushed >= MAX_CASES)
                $fatal(1, "scoreboard capacity exceeded");
            expected[pushed] = calculate_dot();
            pushed = pushed + 1;
        end
    endtask

    task automatic drive_uniform(input integer p, input integer w, input integer bubble_after);
        integer lane;
        begin
            @(negedge clk);
            for (lane = 0; lane < 9; lane = lane + 1) begin
                win[lane] = p;
                weight[lane] = w;
            end
            in_valid = 1'b1;
            accept_current();
            if (bubble_after) begin
                @(negedge clk);
                in_valid = 1'b0;
            end
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && out_valid) begin
            if (popped >= pushed) begin
                $display("FAIL unexpected out_valid dot=%0d", dot);
                errors = errors + 1;
            end else if ($signed(dot) !== $signed(expected[popped])) begin
                $display("FAIL result=%0d expected=%0d actual=%0d",
                         popped, $signed(expected[popped]), $signed(dot));
                errors = errors + 1;
            end
            popped = popped + 1;
        end
    end

    initial begin
        pushed = 0;
        popped = 0;
        errors = 0;
        for (i = 0; i < 9; i = i + 1) begin
            win[i] = 0;
            weight[i] = 0;
        end

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Signed extrema, zeros, bubbles, and consecutive transactions.
        drive_uniform(1, 1, 0);
        drive_uniform(127, 127, 0);
        drive_uniform(-128, -128, 1);
        drive_uniform(-128, 127, 1);
        drive_uniform(0, -128, 0);

        @(negedge clk);
        win[0] = 10; win[1] = 20; win[2] = 30;
        win[3] = 40; win[4] = 50; win[5] = 60;
        win[6] = 70; win[7] = 80; win[8] = 90;
        weight[0] = -1; weight[1] = 0; weight[2] = 1;
        weight[3] = -2; weight[4] = 0; weight[5] = 2;
        weight[6] = -1; weight[7] = 0; weight[8] = 1;
        in_valid = 1'b1;
        accept_current();

        @(negedge clk);
        in_valid = 1'b0;
        repeat (12) @(negedge clk);

        if (popped != pushed) begin
            $display("FAIL missing outputs expected=%0d actual=%0d", pushed, popped);
            errors = errors + 1;
        end
        if (errors != 0)
            $fatal(1, "mac_array scoreboard failed: errors=%0d", errors);

        $display("PASS mac_array: transactions=%0d", pushed);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "mac_array timeout");
    end
endmodule
