`timescale 1ns/1ps

module tb_controller_contract;
    localparam integer IMG_SIZE = 8;
    localparam integer DEPTH = 64;
    localparam integer OUT_DEPTH = 36;
    localparam integer ADDR_W = 6;
    localparam integer OUT_ADDR_W = 6;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic mac_out_valid = 1'b0;
    logic ib_rd_en;
    logic [ADDR_W-1:0] ib_rd_addr;
    logic wg_in_valid;
    logic ob_wr_en;
    logic [OUT_ADDR_W-1:0] ob_wr_addr;
    logic busy;
    logic done;

    integer reads;
    integer writes;
    integer errors;
    integer valid_sent;
    logic previous_ib_rd_en;
    logic previous_done;

    controller #(
        .IMG_SIZE(IMG_SIZE),
        .PIPE_LAT(7)
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

    always #5 clk = ~clk;

    // Sample at the active write/read edge.  Sampling at the following
    // negedge would observe the already-incremented registered addresses.
    always @(posedge clk) begin
        if (!rst_n) begin
            previous_ib_rd_en = 1'b0;
            previous_done = 1'b0;
        end else begin
            if (wg_in_valid !== previous_ib_rd_en) begin
                $display("FAIL wg_in_valid alignment expected=%0b actual=%0b", previous_ib_rd_en, wg_in_valid);
                errors = errors + 1;
            end
            if (ib_rd_en) begin
                if (ib_rd_addr !== reads[ADDR_W-1:0]) begin
                    $display("FAIL read address expected=%0d actual=%0d", reads, ib_rd_addr);
                    errors = errors + 1;
                end
                reads = reads + 1;
            end
            if (ob_wr_en) begin
                if (ob_wr_addr !== writes[OUT_ADDR_W-1:0]) begin
                    $display("FAIL write address expected=%0d actual=%0d", writes, ob_wr_addr);
                    errors = errors + 1;
                end
                if (ob_wr_addr >= OUT_DEPTH) begin
                    $display("FAIL write address outside output buffer: %0d", ob_wr_addr);
                    errors = errors + 1;
                end
                writes = writes + 1;
            end
            if (done && previous_done) begin
                $display("FAIL done wider than one cycle");
                errors = errors + 1;
            end
            previous_ib_rd_en = ib_rd_en;
            previous_done = done;
        end
    end

    initial begin
        reads = 0;
        writes = 0;
        errors = 0;
        valid_sent = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        if (busy || done)
            $fatal(1, "controller not idle after reset");

        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done) begin
            @(negedge clk);
            // Approximate the legal 6x6 output interval. Exactly 36 valid results are supplied.
            if ((reads >= 24) && (valid_sent < OUT_DEPTH)) begin
                mac_out_valid = 1'b1;
                valid_sent = valid_sent + 1;
            end else begin
                mac_out_valid = 1'b0;
            end
            // Busy-time start must be ignored.
            if (reads == 32)
                start = 1'b1;
            else
                start = 1'b0;
        end

        @(negedge clk);
        start = 1'b0;
        mac_out_valid = 1'b0;
        repeat (3) @(negedge clk);

        if (reads != DEPTH) begin
            $display("FAIL read count expected=%0d actual=%0d", DEPTH, reads);
            errors = errors + 1;
        end
        if (writes != OUT_DEPTH) begin
            $display("FAIL write count expected=%0d actual=%0d", OUT_DEPTH, writes);
            errors = errors + 1;
        end
        if (busy || done) begin
            $display("FAIL controller did not return to idle busy=%0b done=%0b", busy, done);
            errors = errors + 1;
        end
        if (errors != 0)
            $fatal(1, "controller contract failed: errors=%0d", errors);

        $display("PASS controller: reads=%0d writes=%0d", reads, writes);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "controller timeout");
    end
endmodule
