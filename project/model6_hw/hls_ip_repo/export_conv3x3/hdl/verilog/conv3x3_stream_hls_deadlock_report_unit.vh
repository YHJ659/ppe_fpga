   
    parameter PROC_NUM = 3;
    parameter ST_IDLE = 3'b000;
    parameter ST_FILTER_FAKE = 3'b001;
    parameter ST_DL_DETECTED = 3'b010;
    parameter ST_DL_REPORT = 3'b100;
   

    reg [2:0] CS_fsm;
    reg [2:0] NS_fsm;
    reg [PROC_NUM - 1:0] dl_detect_reg;
    reg [PROC_NUM - 1:0] dl_done_reg;
    reg [PROC_NUM - 1:0] origin_reg;
    reg [PROC_NUM - 1:0] dl_in_vec_reg;
    reg [31:0] dl_keep_cnt;
    integer i;
    integer fp;

    // FSM State machine
    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            CS_fsm <= ST_IDLE;
        end
        else begin
            CS_fsm <= NS_fsm;
        end
    end
    always @ (CS_fsm or dl_in_vec or dl_detect_reg or dl_done_reg or dl_in_vec or origin_reg or dl_keep_cnt) begin
        case (CS_fsm)
            ST_IDLE : begin
                if (|dl_in_vec) begin
                    NS_fsm = ST_FILTER_FAKE;
                end
                else begin
                    NS_fsm = ST_IDLE;
                end
            end
            ST_FILTER_FAKE: begin
                if (dl_keep_cnt >= 32'd1000) begin
                    NS_fsm = ST_DL_DETECTED;
                end
                else if (dl_detect_reg != (dl_detect_reg & dl_in_vec)) begin
                    NS_fsm = ST_IDLE;
                end
                else begin
                    NS_fsm = ST_FILTER_FAKE;
                end
            end
            ST_DL_DETECTED: begin
                // has unreported deadlock cycle
                if (dl_detect_reg != dl_done_reg) begin
                    NS_fsm = ST_DL_REPORT;
                end
                else begin
                    NS_fsm = ST_DL_DETECTED;
                end
            end
            ST_DL_REPORT: begin
                if (|(dl_in_vec & origin_reg)) begin
                    NS_fsm = ST_DL_DETECTED;
                end
                else begin
                    NS_fsm = ST_DL_REPORT;
                end
            end
            default: NS_fsm = ST_IDLE;
        endcase
    end

    // dl_detect_reg record the procs that first detect deadlock
    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            dl_detect_reg <= 'b0;
        end
        else begin
            if (CS_fsm == ST_IDLE) begin
                dl_detect_reg <= dl_in_vec;
            end
        end
    end

    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            dl_keep_cnt <= 32'h0;
        end
        else begin
            if (CS_fsm == ST_FILTER_FAKE && (dl_detect_reg == (dl_detect_reg & dl_in_vec))) begin
                dl_keep_cnt <= dl_keep_cnt + 32'h1;
            end
            else if (CS_fsm == ST_FILTER_FAKE && (dl_detect_reg != (dl_detect_reg & dl_in_vec))) begin
                dl_keep_cnt <= 32'h0;
            end
        end
    end

    // dl_detect_out keeps in high after deadlock detected
    assign dl_detect_out = (|dl_detect_reg) && (CS_fsm == ST_DL_DETECTED || CS_fsm == ST_DL_REPORT);

    // dl_done_reg record the cycles has been reported
    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            dl_done_reg <= 'b0;
        end
        else begin
            if ((CS_fsm == ST_DL_REPORT) && (|(dl_in_vec & dl_detect_reg) == 'b1)) begin
                dl_done_reg <= dl_done_reg | dl_in_vec;
            end
        end
    end

    // clear token once a cycle is done
    assign token_clear = (CS_fsm == ST_DL_REPORT) ? ((|(dl_in_vec & origin_reg)) ? 'b1 : 'b0) : 'b0;

    // origin_reg record the current cycle start id
    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            origin_reg <= 'b0;
        end
        else begin
            if (CS_fsm == ST_DL_DETECTED) begin
                origin_reg <= origin;
            end
        end
    end
   
    // origin will be valid for only one cycle
    wire [PROC_NUM*PROC_NUM - 1:0] origin_tmp;
    assign origin_tmp[PROC_NUM - 1:0] = (dl_detect_reg[0] & ~dl_done_reg[0]) ? 'b1 : 'b0;
    genvar j;
    generate
    for(j = 1;j < PROC_NUM;j = j + 1) begin: F1
        assign origin_tmp[j*PROC_NUM +: PROC_NUM] = (dl_detect_reg[j] & ~dl_done_reg[j]) ? ('b1 << j) : origin_tmp[(j - 1)*PROC_NUM +: PROC_NUM];
    end
    endgenerate
    always @ (CS_fsm or origin_tmp) begin
        if (CS_fsm == ST_DL_DETECTED) begin
            origin = origin_tmp[(PROC_NUM - 1)*PROC_NUM +: PROC_NUM];
        end
        else begin
            origin = 'b0;
        end
    end

    
    // dl_in_vec_reg record the current cycle dl_in_vec
    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            dl_in_vec_reg <= 'b0;
        end
        else begin
            if (CS_fsm == ST_DL_DETECTED) begin
                dl_in_vec_reg <= origin;
            end
            else if (CS_fsm == ST_DL_REPORT) begin
                dl_in_vec_reg <= dl_in_vec;
            end
        end
    end
    
    // find_df_deadlock to report the deadlock
    always @ (negedge dl_reset or posedge dl_clock) begin
        if (~dl_reset) begin
            find_df_deadlock <= 1'b0;
        end
        else begin
            if (CS_fsm == ST_DL_DETECTED && dl_detect_reg == dl_done_reg) begin
                find_df_deadlock <= 1'b1;
            end
            else if (CS_fsm == ST_IDLE) begin
                find_df_deadlock <= 1'b0;
            end
        end
    end
    
    // get the first valid proc index in dl vector
    function integer proc_index(input [PROC_NUM - 1:0] dl_vec);
        begin
            proc_index = 0;
            for (i = 0; i < PROC_NUM; i = i + 1) begin
                if (dl_vec[i]) begin
                    proc_index = i;
                end
            end
        end
    endfunction

    // get the proc path based on dl vector
    function [424:0] proc_path(input [PROC_NUM - 1:0] dl_vec);
        integer index;
        begin
            index = proc_index(dl_vec);
            case (index)
                0 : begin
                    proc_path = "conv3x3_stream_conv3x3_stream.load_weights_U0";
                end
                1 : begin
                    proc_path = "conv3x3_stream_conv3x3_stream.produce_windows_U0";
                end
                2 : begin
                    proc_path = "conv3x3_stream_conv3x3_stream.compute_stage_U0";
                end
                default : begin
                    proc_path = "unknown";
                end
            endcase
        end
    endfunction

    // print the headlines of deadlock detection
    task print_dl_head;
        begin
            $display("\n//////////////////////////////////////////////////////////////////////////////");
            $display("// ERROR!!! DEADLOCK DETECTED at %0t ns! SIMULATION WILL BE STOPPED! //", $time);
            $display("//////////////////////////////////////////////////////////////////////////////");
            fp = $fopen("deadlock_db.dat", "w");
        end
    endtask

    // print the start of a cycle
    task print_cycle_start(input reg [424:0] proc_path, input integer cycle_id);
        begin
            $display("/////////////////////////");
            $display("// Dependence cycle %0d:", cycle_id);
            $display("// (1): Process: %0s", proc_path);
            $fdisplay(fp, "Dependence_Cycle_ID %0d", cycle_id);
            $fdisplay(fp, "Dependence_Process_ID 1");
            $fdisplay(fp, "Dependence_Process_path %0s", proc_path);
        end
    endtask

    // print the end of deadlock detection
    task print_dl_end(input integer num, input integer record_time);
        begin
            $display("////////////////////////////////////////////////////////////////////////");
            $display("// Totally %0d cycles detected!", num);
            $display("////////////////////////////////////////////////////////////////////////");
            $display("// ERROR!!! DEADLOCK DETECTED at %0t ns! SIMULATION WILL BE STOPPED! //", record_time);
            $display("//////////////////////////////////////////////////////////////////////////////");
            $fdisplay(fp, "Dependence_Cycle_Number %0d", num);
            $fclose(fp);
        end
    endtask

    // print one proc component in the cycle
    task print_cycle_proc_comp(input reg [424:0] proc_path, input integer cycle_comp_id);
        begin
            $display("// (%0d): Process: %0s", cycle_comp_id, proc_path);
            $fdisplay(fp, "Dependence_Process_ID %0d", cycle_comp_id);
            $fdisplay(fp, "Dependence_Process_path %0s", proc_path);
        end
    endtask

    // print one channel component in the cycle
    task print_cycle_chan_comp(input [PROC_NUM - 1:0] dl_vec1, input [PROC_NUM - 1:0] dl_vec2);
        reg [976:0] chan_path;
        integer index1;
        integer index2;
        begin
            index1 = proc_index(dl_vec1);
            index2 = proc_index(dl_vec2);
            case (index1)
                0 : begin
                    case(index2)
                    2: begin
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.t_read) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.i_full_n & load_weights_U0.ap_done & ap_done_reg_0 & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.t_read) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                    end
                    1: begin
                        if (ap_sync_load_weights_U0_ap_ready & load_weights_U0.ap_idle & ~ap_sync_produce_windows_U0_ap_ready) begin
                            $display("//      Blocked by input sync logic with process : 'conv3x3_stream_conv3x3_stream.produce_windows_U0'");
                        end
                    end
                    endcase
                end
                1 : begin
                    case(index2)
                    2: begin
                        if (~produce_windows_U0.win_s_blk_n) begin
                            if (~win_s_U.if_empty_n) begin
                                $display("//      Blocked by empty input FIFO 'conv3x3_stream_conv3x3_stream.win_s_U' written by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.win_s_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~win_s_U.if_full_n) begin
                                $display("//      Blocked by full output FIFO 'conv3x3_stream_conv3x3_stream.win_s_U' read by process 'conv3x3_stream_conv3x3_stream.compute_stage_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.win_s_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                    end
                    0: begin
                        if (ap_sync_produce_windows_U0_ap_ready & produce_windows_U0.ap_idle & ~ap_sync_load_weights_U0_ap_ready) begin
                            $display("//      Blocked by input sync logic with process : 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                        end
                    end
                    endcase
                end
                2 : begin
                    case(index2)
                    1: begin
                        if (~compute_stage_U0.win_s_blk_n) begin
                            if (~win_s_U.if_empty_n) begin
                                $display("//      Blocked by empty input FIFO 'conv3x3_stream_conv3x3_stream.win_s_U' written by process 'conv3x3_stream_conv3x3_stream.produce_windows_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.win_s_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~win_s_U.if_full_n) begin
                                $display("//      Blocked by full output FIFO 'conv3x3_stream_conv3x3_stream.win_s_U' read by process 'conv3x3_stream_conv3x3_stream.produce_windows_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.win_s_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                    end
                    0: begin
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_131_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_132_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_133_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_134_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_135_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_136_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_137_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_138_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_139_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_140_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_141_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_142_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_143_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_144_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_145_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_146_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_147_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_148_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_149_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_150_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_151_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_152_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_153_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_154_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_155_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_156_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_157_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_158_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_159_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_160_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_161_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_162_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_99_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_98_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_97_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_96_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_95_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_94_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_93_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_92_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_91_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_90_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_89_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_88_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_87_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_86_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_85_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_84_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_83_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_82_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_81_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_80_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_79_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_78_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_77_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_76_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_75_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_74_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_73_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_72_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_71_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_70_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_69_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_68_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_67_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_66_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_65_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_64_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_63_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_62_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_61_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_60_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_59_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_58_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_57_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_56_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_55_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_54_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_53_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_52_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_51_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_50_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_49_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_48_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_47_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_46_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_45_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_44_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_43_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_42_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_41_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_40_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_39_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_38_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_37_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_36_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_35_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_34_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_33_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_32_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_31_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_30_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_29_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_28_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_27_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_26_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_25_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_24_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_23_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_22_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_21_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_20_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_19_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_18_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_17_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_16_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_15_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_14_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_13_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_12_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_11_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_10_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_9_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_8_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_7_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_6_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_5_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_4_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_3_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_2_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_1_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.t_empty_n & compute_stage_U0.ap_idle & ~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.i_write) begin
                            if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.p_ZZ14conv3x3_streamRN3hls6streamI8in_pix_tLi0EEERNS0_I9out_pix_tLi0EEEPA64_A3_A3_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_11_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_10_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_9_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_8_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_7_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_6_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_5_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_4_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_3_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_2_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_1_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                        if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.t_empty_n & compute_stage_U0.ap_idle & ~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.i_write) begin
                            if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.t_empty_n) begin
                                $display("//      Blocked by empty input PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U' written by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U");
                                $fdisplay(fp, "Dependence_Channel_status EMPTY");
                            end
                            else if (~conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U.i_full_n) begin
                                $display("//      Blocked by full output PIPO 'conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U' read by process 'conv3x3_stream_conv3x3_stream.load_weights_U0'");
                                $fdisplay(fp, "Dependence_Channel_path conv3x3_stream_conv3x3_stream.conv3x3_stream_stream_stream_ap_int_8_64_3_3_int_local_weight_U");
                                $fdisplay(fp, "Dependence_Channel_status FULL");
                            end
                        end
                    end
                    endcase
                end
            endcase
        end
    endtask

    // report
    initial begin : report_deadlock
        integer cycle_id;
        integer cycle_comp_id;
        integer record_time;
        wait (dl_reset == 1);
        cycle_id = 1;
        record_time = 0;
        while (1) begin
            @ (negedge dl_clock);
            case (CS_fsm)
                ST_DL_DETECTED: begin
                    cycle_comp_id = 2;
                    if (dl_detect_reg != dl_done_reg) begin
                        if (dl_done_reg == 'b0) begin
                            print_dl_head;
                            record_time = $time;
                        end
                        print_cycle_start(proc_path(origin), cycle_id);
                        cycle_id = cycle_id + 1;
                    end
                    else begin
                        print_dl_end((cycle_id - 1),record_time);
                        @(negedge dl_clock);
                        @(negedge dl_clock);
                        $finish;
                    end
                end
                ST_DL_REPORT: begin
                    if ((|(dl_in_vec)) & ~(|(dl_in_vec & origin_reg))) begin
                        print_cycle_chan_comp(dl_in_vec_reg, dl_in_vec);
                        print_cycle_proc_comp(proc_path(dl_in_vec), cycle_comp_id);
                        cycle_comp_id = cycle_comp_id + 1;
                    end
                    else begin
                        print_cycle_chan_comp(dl_in_vec_reg, dl_in_vec);
                    end
                end
            endcase
        end
    end
 
