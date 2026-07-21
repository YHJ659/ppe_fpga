// Educational 4-lane signed Q1.7 MAC.
// Replace this module with the team's real convolution/accelerator DUT.
module mac_core #(
    parameter int LANES = 4,
    parameter int IN_W = 8,
    parameter int ACC_W = 32,
    parameter int OUT_W = 8,
    parameter int FRAC_BITS = 7
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic signed [IN_W-1:0] x [0:LANES-1],
    input  logic signed [IN_W-1:0] w [0:LANES-1],
    input  logic signed [ACC_W-1:0] bias_accumulator,
    output logic done,
    output logic signed [ACC_W-1:0] accumulator,
    output logic signed [OUT_W-1:0] y
);
    logic signed [ACC_W-1:0] acc_comb;
    integer lane;

    always_comb begin
        acc_comb = bias_accumulator;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            acc_comb = acc_comb + x[lane] * w[lane];
        end
    end

    function automatic logic signed [OUT_W-1:0] quantize_saturate(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W:0] magnitude;
        logic signed [ACC_W:0] shifted;
        logic signed [ACC_W:0] maximum;
        logic signed [ACC_W:0] minimum;
        begin
            maximum = (1 <<< (OUT_W - 1)) - 1;
            minimum = -(1 <<< (OUT_W - 1));
            if (value < 0) begin
                magnitude = -value;
                shifted = -((magnitude + (1 <<< (FRAC_BITS - 1))) >>> FRAC_BITS);
            end else begin
                shifted = (value + (1 <<< (FRAC_BITS - 1))) >>> FRAC_BITS;
            end

            if (shifted > maximum)
                quantize_saturate = maximum[OUT_W-1:0];
            else if (shifted < minimum)
                quantize_saturate = minimum[OUT_W-1:0];
            else
                quantize_saturate = shifted[OUT_W-1:0];
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            accumulator <= '0;
            y <= '0;
        end else begin
            done <= 1'b0;
            if (start) begin
                accumulator <= acc_comb;
                y <= quantize_saturate(acc_comb);
                done <= 1'b1;
            end
        end
    end
endmodule

