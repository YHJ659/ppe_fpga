
wire kernel_monitor_reset;
wire kernel_monitor_clock;
wire kernel_monitor_report;
assign kernel_monitor_reset = ~ap_rst_n;
assign kernel_monitor_clock = ap_clk;
assign kernel_monitor_report = 1'b0;
wire [1:0] axis_block_sigs;
wire [5:0] inst_idle_sigs;
wire [2:0] inst_block_sigs;
wire kernel_block;

assign axis_block_sigs[0] = ~produce_windows_U0.in_s_TDATA_blk_n;
assign axis_block_sigs[1] = ~compute_stage_U0.out_s_TDATA_blk_n;

assign inst_idle_sigs[0] = load_weights_U0.ap_idle;
assign inst_block_sigs[0] = (load_weights_U0.ap_done & ~load_weights_U0.ap_continue);
assign inst_idle_sigs[1] = produce_windows_U0.ap_idle;
assign inst_block_sigs[1] = (produce_windows_U0.ap_done & ~produce_windows_U0.ap_continue) | ~produce_windows_U0.win_s_blk_n;
assign inst_idle_sigs[2] = compute_stage_U0.ap_idle;
assign inst_block_sigs[2] = (compute_stage_U0.ap_done & ~compute_stage_U0.ap_continue) | ~compute_stage_U0.win_s_blk_n;

assign inst_idle_sigs[3] = 1'b0;
assign inst_idle_sigs[4] = produce_windows_U0.ap_idle;
assign inst_idle_sigs[5] = compute_stage_U0.ap_idle;

conv3x3_stream_hls_deadlock_idx0_monitor conv3x3_stream_hls_deadlock_idx0_monitor_U (
    .clock(kernel_monitor_clock),
    .reset(kernel_monitor_reset),
    .axis_block_sigs(axis_block_sigs),
    .inst_idle_sigs(inst_idle_sigs),
    .inst_block_sigs(inst_block_sigs),
    .block(kernel_block)
);


always @ (kernel_block or kernel_monitor_reset) begin
    if (kernel_block == 1'b1 && kernel_monitor_reset == 1'b0) begin
        find_kernel_block = 1'b1;
    end
    else begin
        find_kernel_block = 1'b0;
    end
end
