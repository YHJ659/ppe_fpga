`timescale 1ns/1ps

module tb_mac_core_strict;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic signed [7:0] x [0:3];
    logic signed [7:0] w [0:3];
    logic signed [31:0] bias_accumulator = 0;
    logic done;
    logic signed [31:0] accumulator;
    logic signed [7:0] y;
    integer errors = 0;
    integer lane;

    mac_core dut (
        .clk(clk), .rst_n(rst_n), .start(start), .x(x), .w(w),
        .bias_accumulator(bias_accumulator), .done(done),
        .accumulator(accumulator), .y(y)
    );

    always #5 clk = ~clk;

    task automatic run_uniform(
        input integer xv,
        input integer wv,
        input integer bias,
        input integer expected_acc,
        input integer expected_y
    );
        begin
            @(negedge clk);
            for (lane = 0; lane < 4; lane = lane + 1) begin
                x[lane] = xv;
                w[lane] = wv;
            end
            bias_accumulator = bias;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            if (!done) begin
                $display("FAIL done not asserted for accepted start");
                errors = errors + 1;
            end
            if ($signed(accumulator) !== expected_acc) begin
                $display("FAIL accumulator expected=%0d actual=%0d", expected_acc, $signed(accumulator));
                errors = errors + 1;
            end
            if ($signed(y) !== expected_y) begin
                $display("FAIL y expected=%0d actual=%0d", expected_y, $signed(y));
                errors = errors + 1;
            end
            @(negedge clk);
            if (done) begin
                $display("FAIL done wider than one cycle");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (lane = 0; lane < 4; lane = lane + 1) begin
            x[lane] = 0;
            w[lane] = 0;
        end
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        run_uniform(1, 1, 0, 4, 0);
        run_uniform(64, 1, 0, 256, 2);
        run_uniform(-64, 1, 0, -256, -2);

        // Signed ACC_W=32 wrap is part of the current RTL behavior.
        run_uniform(127, 127, 32'h7fffffff, -2147419133, -128);
        run_uniform(-128, 127, 32'h80000000, 2147418624, 127);

        if (errors != 0)
            $fatal(1, "mac_core strict test failed: errors=%0d", errors);
        $display("PASS mac_core strict: accumulator, wrap, requantization, done pulse");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "mac_core timeout");
    end
endmodule
