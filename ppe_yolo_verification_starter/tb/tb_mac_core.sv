`timescale 1ns/1ps

module tb_mac_core;
    localparam int LANES = 4;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic signed [7:0] x [0:LANES-1];
    logic signed [7:0] w [0:LANES-1];
    logic signed [31:0] bias_accumulator;
    logic done;
    logic signed [31:0] accumulator;
    logic signed [7:0] y;

    integer vector_file;
    integer scan_count;
    integer vector_count = 0;
    integer error_count = 0;
    integer x0, x1, x2, x3, w0, w1, w2, w3, bias_value, expected;

    mac_core dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .x(x),
        .w(w),
        .bias_accumulator(bias_accumulator),
        .done(done),
        .accumulator(accumulator),
        .y(y)
    );

    always #5 clk = ~clk;

    task automatic apply_vector;
        begin
            @(negedge clk);
            x[0] = x0; x[1] = x1; x[2] = x2; x[3] = x3;
            w[0] = w0; w[1] = w1; w[2] = w2; w[3] = w3;
            bias_accumulator = bias_value;
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
            vector_count = vector_count + 1;
            if (!done) begin
                $display("[FAIL] vector=%0d done was not asserted", vector_count);
                error_count = error_count + 1;
            end else if ($signed(y) != expected) begin
                $display(
                    "[FAIL] vector=%0d expected=%0d actual=%0d accumulator=%0d",
                    vector_count, expected, $signed(y), $signed(accumulator)
                );
                error_count = error_count + 1;
            end else begin
                $display("[PASS] vector=%0d output=%0d", vector_count, $signed(y));
            end
        end
    endtask

    initial begin
        x[0] = 0; x[1] = 0; x[2] = 0; x[3] = 0;
        w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 0;
        bias_accumulator = 0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        vector_file = $fopen("vectors/mac_vectors.txt", "r");
        if (vector_file == 0) begin
            $fatal(1, "cannot open vectors/mac_vectors.txt; run generate_mac_vectors.py first");
        end

        while (!$feof(vector_file)) begin
            scan_count = $fscanf(
                vector_file,
                "%d %d %d %d %d %d %d %d %d %d\n",
                x0, x1, x2, x3, w0, w1, w2, w3, bias_value, expected
            );
            if (scan_count == 10)
                apply_vector();
        end
        $fclose(vector_file);

        if (error_count == 0)
            $display("RESULT: PASS (%0d vectors)", vector_count);
        else
            $fatal(1, "RESULT: FAIL (%0d errors / %0d vectors)", error_count, vector_count);
        $finish;
    end
endmodule
