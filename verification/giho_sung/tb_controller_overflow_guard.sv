`timescale 1ns/1ps

// This regression intentionally fails on commit f7bc21d.  A correct controller
// must never issue output-buffer address 36 when OUT_DEPTH is 36.
module tb_controller_overflow_guard;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic mac_out_valid = 1'b0;
    logic ib_rd_en;
    logic [5:0] ib_rd_addr;
    logic wg_in_valid;
    logic ob_wr_en;
    logic [5:0] ob_wr_addr;
    logic busy;
    logic done;
    integer sent;

    controller #(.IMG_SIZE(8), .PIPE_LAT(7)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .ib_rd_en(ib_rd_en), .ib_rd_addr(ib_rd_addr),
        .wg_in_valid(wg_in_valid), .mac_out_valid(mac_out_valid),
        .ob_wr_en(ob_wr_en), .ob_wr_addr(ob_wr_addr),
        .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        if (rst_n && ob_wr_en && (ob_wr_addr >= 36))
            $fatal(1, "output-buffer overflow reproduced: addr=%0d", ob_wr_addr);
    end

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (ib_rd_addr >= 20);
        for (sent = 0; sent < 37; sent = sent + 1) begin
            @(negedge clk);
            mac_out_valid = 1'b1;
        end
        @(negedge clk);
        mac_out_valid = 1'b0;
        wait (done);
        repeat (2) @(negedge clk);
        $display("PASS overflow guard present");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "controller overflow probe timeout");
    end
endmodule
