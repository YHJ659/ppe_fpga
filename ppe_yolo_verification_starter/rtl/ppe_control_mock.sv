// Minimal START/BUSY/DONE behavior for learning control-path verification.
// This is a mock, not a YOLO accelerator.
module ppe_control_mock (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [15:0] requested_cycles,
    output logic busy,
    output logic done,
    output logic [31:0] completed_jobs
);
    logic [15:0] remaining_cycles;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            completed_jobs <= 32'd0;
            remaining_cycles <= 16'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                remaining_cycles <= (requested_cycles == 0) ? 16'd1 : requested_cycles;
            end else if (busy) begin
                if (remaining_cycles <= 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    completed_jobs <= completed_jobs + 1'b1;
                    remaining_cycles <= 16'd0;
                end else begin
                    remaining_cycles <= remaining_cycles - 1'b1;
                end
            end
        end
    end
endmodule

