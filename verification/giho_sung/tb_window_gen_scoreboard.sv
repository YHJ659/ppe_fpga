`timescale 1ns/1ps

module tb_window_gen_scoreboard #(
    parameter integer IMG_SIZE = 8
);
    localparam integer DATA_W = 8;
    localparam integer OUT_SIZE = IMG_SIZE - 2;
    localparam integer EXPECTED_PER_FRAME = OUT_SIZE * OUT_SIZE;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic in_valid = 1'b0;
    logic signed [DATA_W-1:0] pixel_in = '0;
    logic signed [DATA_W-1:0] win [0:8];
    logic win_valid;

    integer frame_base;
    integer observed;
    integer errors;

    window_gen #(
        .IMG_SIZE(IMG_SIZE),
        .DATA_W(DATA_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .pixel_in(pixel_in),
        .win(win),
        .win_valid(win_valid)
    );

    always #5 clk = ~clk;

    task automatic check_current_window;
        integer out_r;
        integer out_c;
        integer kr;
        integer kc;
        integer k;
        integer expected;
        begin
            if (observed >= EXPECTED_PER_FRAME) begin
                $display("FAIL extra window: frame_base=%0d observed=%0d", frame_base, observed);
                errors = errors + 1;
            end else begin
                out_r = observed / OUT_SIZE;
                out_c = observed % OUT_SIZE;
                for (kr = 0; kr < 3; kr = kr + 1) begin
                    for (kc = 0; kc < 3; kc = kc + 1) begin
                        k = kr * 3 + kc;
                        expected = frame_base + (out_r + kr) * IMG_SIZE + out_c + kc;
                        if ($signed(win[k]) !== expected) begin
                            $display("FAIL frame_base=%0d window=%0d lane=%0d expected=%0d actual=%0d",
                                     frame_base, observed, k, expected, $signed(win[k]));
                            errors = errors + 1;
                        end
                    end
                end
            end
            observed = observed + 1;
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && win_valid)
            check_current_window();
    end

    task automatic send_frame(input integer base, input integer add_bubbles);
        integer i;
        begin
            frame_base = base;
            observed = 0;
            for (i = 0; i < IMG_SIZE * IMG_SIZE; i = i + 1) begin
                if (add_bubbles && ((i % 7) == 3)) begin
                    @(negedge clk);
                    in_valid = 1'b0;
                end
                @(negedge clk);
                in_valid = 1'b1;
                pixel_in = base + i;
            end
            @(negedge clk);
            in_valid = 1'b0;
            repeat (3) @(negedge clk);
            if (observed != EXPECTED_PER_FRAME) begin
                $display("FAIL frame_base=%0d expected_windows=%0d actual_windows=%0d",
                         base, EXPECTED_PER_FRAME, observed);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        frame_base = 0;
        observed = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // No reset between frames: this is part of the frame-state contract.
        send_frame(0, 1);
        send_frame(64, 1);

        if (errors != 0)
            $fatal(1, "window_gen scoreboard failed: IMG_SIZE=%0d errors=%0d", IMG_SIZE, errors);

        $display("PASS window_gen: IMG_SIZE=%0d frames=2 windows=%0d",
                 IMG_SIZE, 2 * EXPECTED_PER_FRAME);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "window_gen timeout");
    end
endmodule
