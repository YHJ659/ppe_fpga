`timescale 1ns/1ps

module tb_ppe_control;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [15:0] requested_cycles = 16'd0;
    logic busy;
    logic done;
    logic [31:0] completed_jobs;
    integer errors = 0;

    ppe_control_mock dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .requested_cycles(requested_cycles),
        .busy(busy),
        .done(done),
        .completed_jobs(completed_jobs)
    );

    always #5 clk = ~clk;

    task automatic launch(input integer cycles);
        begin
            @(negedge clk);
            requested_cycles = cycles;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            if (!busy) begin
                $display("[FAIL] busy did not assert after start");
                errors = errors + 1;
            end
        end
    endtask

    task automatic wait_done(input integer timeout_cycles);
        integer waited;
        begin
            waited = 0;
            while (!done && waited < timeout_cycles) begin
                @(posedge clk);
                #1;
                waited = waited + 1;
            end
            if (!done) begin
                $display("[FAIL] timeout waiting for done");
                errors = errors + 1;
            end else begin
                $display("[PASS] done after %0d observed cycles", waited);
            end
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        launch(3);
        // A second start while busy must not create another job.
        @(negedge clk);
        start = 1'b1;
        requested_cycles = 1;
        @(negedge clk);
        start = 1'b0;
        wait_done(10);
        if (completed_jobs != 1) begin
            $display("[FAIL] expected one completed job, actual=%0d", completed_jobs);
            errors = errors + 1;
        end

        launch(0);
        wait_done(5);
        if (completed_jobs != 2) begin
            $display("[FAIL] expected two completed jobs, actual=%0d", completed_jobs);
            errors = errors + 1;
        end

        @(negedge clk);
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        if (busy || done || completed_jobs != 0) begin
            $display("[FAIL] reset did not clear state");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("RESULT: PASS");
        else
            $fatal(1, "RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

