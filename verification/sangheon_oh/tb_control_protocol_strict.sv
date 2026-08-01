`timescale 1ns/1ps

module tb_control_protocol_strict;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [15:0] requested_cycles = 0;
    logic busy;
    logic done;
    logic [31:0] completed_jobs;
    integer errors = 0;
    integer expected_jobs = 0;

    ppe_control_mock dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .requested_cycles(requested_cycles), .busy(busy), .done(done),
        .completed_jobs(completed_jobs)
    );

    always #5 clk = ~clk;

    task automatic run_job(input integer requested, input integer inject_busy_start);
        integer effective;
        integer cycle;
        begin
            effective = (requested == 0) ? 1 : requested;
            @(negedge clk);
            requested_cycles = requested;
            start = 1'b1;
            @(posedge clk);
            #1;
            if (!busy || done) begin
                $display("FAIL acceptance requested=%0d busy=%0b done=%0b", requested, busy, done);
                errors = errors + 1;
            end
            @(negedge clk);
            start = 1'b0;

            for (cycle = 1; cycle <= effective; cycle = cycle + 1) begin
                if (inject_busy_start && cycle == 1) begin
                    start = 1'b1;
                    requested_cycles = 1;
                end
                @(posedge clk);
                #1;
                if (cycle < effective) begin
                    if (!busy || done) begin
                        $display("FAIL mid-job requested=%0d cycle=%0d busy=%0b done=%0b",
                                 requested, cycle, busy, done);
                        errors = errors + 1;
                    end
                end else begin
                    expected_jobs = expected_jobs + 1;
                    if (busy || !done || completed_jobs != expected_jobs) begin
                        $display("FAIL completion requested=%0d cycle=%0d busy=%0b done=%0b jobs=%0d expected_jobs=%0d",
                                 requested, cycle, busy, done, completed_jobs, expected_jobs);
                        errors = errors + 1;
                    end
                end
                @(negedge clk);
                start = 1'b0;
            end

            @(posedge clk);
            #1;
            if (done) begin
                $display("FAIL done wider than one cycle for requested=%0d", requested);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        run_job(3, 1);
        run_job(0, 0);
        run_job(1, 0);
        run_job(7, 0);

        @(negedge clk);
        requested_cycles = 10;
        start = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        start = 1'b0;
        rst_n = 1'b0;
        #1;
        if (busy || done || completed_jobs != 0) begin
            $display("FAIL async reset did not clear state");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "control protocol failed: errors=%0d", errors);
        $display("PASS control protocol: exact latency, busy-start, done width, async reset");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "control protocol timeout");
    end
endmodule
