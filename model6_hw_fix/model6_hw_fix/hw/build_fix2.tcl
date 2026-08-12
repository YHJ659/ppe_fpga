# =====================================================================
# build_ppe_model6_fix2.tcl
#
# 팀이 만든 ppe_fpga_yoo.xsa 와 동일한 블록디자인을 재현하고,
# 빠져 있던 DMA 메모리 포트 연결만 추가한다.
#
#   [원본 문제] axi_dma_0.M_AXI_MM2S / M_AXI_S2MM 이 __NOC__ (미연결)
#               PS 에 S_AXI_HP* 슬레이브 포트가 하나도 없음
#               -> DMA 가 DDR 을 못 읽어 1픽셀도 전송 못 함
#   [수정]      S_AXI_HP0_FPD 활성화 + SmartConnect 로 DMA 마스터 2개 연결
#               + DDR 주소 세그먼트 배정
#
# 구조는 design_1.hwh 에서 추출한 연결/파라미터를 그대로 따랐다.
# 주소도 원본과 동일하게 고정하여 ps_run_model6.py 를 수정 없이 쓴다.
# =====================================================================
set work_root "/DATA/home/edu030/ppe_fpga_experiments/model6_fix2"
set build_dir [file join $work_root build]
set out_dir   [file join $work_root output]
set coe_dir   [file join $work_root coe]
set ip_repo   [file join $work_root ip_repo]
file mkdir $out_dir

create_project -force ppe_model6_fix2 $build_dir -part xck26-sfvc784-2LV-c
config_ip_cache -disable_cache
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property target_language Verilog [current_project]
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog

create_bd_design design_1

# ------------------------------------------------------------ PS / 인프라
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {32} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100}] $ps

set reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps8_0_99M]
set clk    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
               [get_bd_pins rst_ps8_0_99M/ext_reset_in]
connect_bd_net $clk [get_bd_pins rst_ps8_0_99M/slowest_sync_clk]
set rstn [get_bd_pins rst_ps8_0_99M/peripheral_aresetn]

# 제어: PS -> 7개 s_axi_control + DMA S_AXI_LITE
set ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ps8_0_axi_periph]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {7}] $ctrl
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
                    [get_bd_intf_pins ps8_0_axi_periph/S00_AXI]

# ★ 추가된 부분: DMA 데이터 경로 -> PS HP0
set data_sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 dma_mem_sc]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $data_sc
connect_bd_intf_net [get_bd_intf_pins dma_mem_sc/M00_AXI] \
                    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# --------------------------------------------------------------- DMA / 변환
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_sg_length_width {26}] $dma
# c_sg_length_width 를 기본값 14 에서 26 으로 올린 이유
#   14 이면 한 번에 보낼 수 있는 길이가 2^14-1 = 16383 B 뿐이다.
#   한 프레임 출력은 256ch x 40 x 40 = 409600 B 라 26번 나눠 받아야 하는데,
#   HLS 스트림에는 TLAST 가 없어서 DMA 가 "길이보다 긴 패킷" 으로 보고
#   첫 조각 직후 S2MM_DMASR 에 DMAIntErr 를 세우고 멈춘다. 즉 나눠 받기는
#   원리상 불가능하고, 한 번에 받는 수밖에 없다.
#   26 이면 67 MB 까지 되므로 다시 걸릴 일이 없다.
#   늘어나는 것은 각 채널의 길이 레지스터와 바이트 카운터 폭(12비트)뿐이라
#   BRAM/URAM/DSP 는 전혀 쓰지 않는다. URAM 이 60/64 로 빠듯한 설계라 이 점이
#   중요하다.
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
                    [get_bd_intf_pins dma_mem_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                    [get_bd_intf_pins dma_mem_sc/S01_AXI]

# 32bit <-> IP 폭 변환 (원본과 동일: 입력 4->128 B, 출력 256->4 B)
set dwc0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 axis_dwidth_converter_0]
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {4} CONFIG.M_TDATA_NUM_BYTES {128}] $dwc0
set dwc1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 axis_dwidth_converter_1]
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {256} CONFIG.M_TDATA_NUM_BYTES {4}] $dwc1

# residual 의 x/fx 도착 순서 차이로 인한 교착 방지 (배선 문서 5절)
foreach f {axis_data_fifo_0 axis_data_fifo_1} {
    set cell [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 $f]
    set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.FIFO_DEPTH {16} \
        CONFIG.FIFO_MEMORY_TYPE {distributed}] $cell
}

# -------------------------------------------------------------- 연산 IP 8개
proc mk {name vlnv} { create_bd_cell -type ip -vlnv $vlnv $name }
mk conv1x1_stream_0        xilinx.com:hls:conv1x1_stream:1.0
mk bn_silu_128_stream_0    xilinx.com:hls:bn_silu_128_stream:1.0
mk split_channel_stream_0  xilinx.com:hls:split_channel_stream:1.0
mk bottleneck_router_0     xilinx.com:hls:bottleneck_router:1.0
mk conv3x3_stream_0        xilinx.com:hls:conv3x3_stream:1.0
mk bn_silu_stream_0        xilinx.com:hls:bn_silu_stream:1.0
mk residual_add_stream_0   xilinx.com:hls:residual_add_stream:1.0
mk concat_channel_stream_0 xilinx.com:hls:concat_channel_stream:1.0

set hls_ips {conv1x1_stream_0 bn_silu_128_stream_0 split_channel_stream_0
             bottleneck_router_0 conv3x3_stream_0 bn_silu_stream_0
             residual_add_stream_0 concat_channel_stream_0}
foreach ip $hls_ips {
    connect_bd_net $clk  [get_bd_pins $ip/ap_clk]
    connect_bd_net $rstn [get_bd_pins $ip/ap_rst_n]
}
# IP 마다 클럭/리셋 핀 이름이 다르다 (dwidth_converter 는 aclk/aresetn,
# data_fifo 는 s_axis_aclk/s_axis_aresetn). 이름을 가정하지 말고 패턴으로 찾는다.
foreach c {axis_dwidth_converter_0 axis_dwidth_converter_1
           axis_data_fifo_0 axis_data_fifo_1} {
    foreach p [get_bd_pins -quiet $c/*aclk] { connect_bd_net $clk $p }
    foreach p [get_bd_pins -quiet $c/*aresetn] { connect_bd_net $rstn $p }
}
connect_bd_net $clk [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins ps8_0_axi_periph/aclk] [get_bd_pins dma_mem_sc/aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]
connect_bd_net $rstn [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins ps8_0_axi_periph/aresetn] [get_bd_pins dma_mem_sc/aresetn]

# ------------------------------------------------- 스트림 (hwh 에서 추출한 15개)
proc s {src dst} {
    connect_bd_intf_net [get_bd_intf_pins $src] [get_bd_intf_pins $dst]
}
s axi_dma_0/M_AXIS_MM2S              axis_dwidth_converter_0/S_AXIS
s axis_dwidth_converter_0/M_AXIS     conv1x1_stream_0/in_s
s conv1x1_stream_0/out_s             bn_silu_128_stream_0/in_s
s bn_silu_128_stream_0/out_s         split_channel_stream_0/in_s
s split_channel_stream_0/y0_s        concat_channel_stream_0/y0_s
s split_channel_stream_0/y1_concat_s concat_channel_stream_0/y1_s
s split_channel_stream_0/y1_router_s bottleneck_router_0/y1_s
s bottleneck_router_0/conv_in_s      conv3x3_stream_0/in_s
s conv3x3_stream_0/out_s             bn_silu_stream_0/in_s
s bn_silu_stream_0/out_s             bottleneck_router_0/bn_out_s
s bottleneck_router_0/res_x_s        axis_data_fifo_0/S_AXIS
s axis_data_fifo_0/M_AXIS            residual_add_stream_0/x_s
s bottleneck_router_0/res_fx_s       axis_data_fifo_1/S_AXIS
s axis_data_fifo_1/M_AXIS            residual_add_stream_0/fx_s
s residual_add_stream_0/out_s        bottleneck_router_0/res_out_s
s bottleneck_router_0/y2_out_s       concat_channel_stream_0/y2_s
s bottleneck_router_0/y3_out_s       concat_channel_stream_0/y3_s
s concat_channel_stream_0/out_s      axis_dwidth_converter_1/S_AXIS
s axis_dwidth_converter_1/M_AXIS     axi_dma_0/S_AXIS_S2MM

# ------------------------------------------------------ 파라미터 BRAM 15개
proc mk_bram {name type width depth coe} {
    set mem [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 $name]
    # 기본이 AXI4 모드라 폭 하한 32bit 가 걸린다. Native/Stand-Alone 먼저.
    set_property -dict [list CONFIG.use_bram_block {Stand_Alone} \
        CONFIG.Interface_Type {Native} CONFIG.Enable_32bit_Address {false} \
        CONFIG.Memory_Type $type] $mem
    set props [list CONFIG.Write_Width_A $width CONFIG.Read_Width_A $width \
        CONFIG.Write_Depth_A $depth \
        CONFIG.Load_Init_File {true} CONFIG.Coe_File $coe \
        CONFIG.Fill_Remaining_Memory_Locations {true} \
        CONFIG.Remaining_Memory_Locations {0} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
        CONFIG.Use_RSTA_Pin {false}]
    if {$type eq "True_Dual_Port_RAM"} {
        lappend props CONFIG.Write_Width_B $width CONFIG.Read_Width_B $width \
            CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
            CONFIG.Use_RSTB_Pin {false}
    }
    set_property -dict $props $mem
}

# 가중치: PORTA/PORTB 둘 다 쓰므로 True Dual Port
mk_bram bmg_cv1_weight   True_Dual_Port_RAM 8  16384 [file join $coe_dir cv1_weight.coe]
mk_bram bmg_conv3_weight True_Dual_Port_RAM 8 147456 [file join $coe_dir conv3x3_weight_bank.coe]
s conv1x1_stream_0/weight_PORTA bmg_cv1_weight/BRAM_PORTA
s conv1x1_stream_0/weight_PORTB bmg_cv1_weight/BRAM_PORTB
s conv3x3_stream_0/weight_PORTA bmg_conv3_weight/BRAM_PORTA
s conv3x3_stream_0/weight_PORTB bmg_conv3_weight/BRAM_PORTB

# 스케일 계열: PORTA 만 사용
#
# 깊이를 4배로 잡는 이유 (보드 실측으로 확정)
#   HLS 가 BRAM 포트에 내보내는 주소는 바이트 주소다. blk_mem_gen 은 워드
#   주소로 읽는다. 원소가 float(4바이트)면 채널 c 를 읽으려 할 때 4c 번 칸이
#   읽히고, 주소선이 8비트뿐이면 256 에서 되감긴다.
#       실측: 읽히는 칸 = (4*c) mod 256   (영입력·실제이미지 128/128 채널 일치)
#   깊이를 4배로 하면 주소선이 2비트 넓어져 안 되감기고, coe_stride4.py 가
#   값을 0,4,8,... 칸에 놓아 주소 4c 가 원소 c 에 정확히 떨어진다.
#   원소가 1바이트인 가중치 BRAM 은 바이트 주소 = 원소 번호라 손댈 게 없다.
#   아래 depth 는 원소 개수 그대로 적고, mk_bram 호출에서 4배로 올린다.
foreach spec {
    {bmg_bn128_bn_scale     bn_silu_128_stream_0 bn_scale      256 bn128_bn_scale.coe}
    {bmg_bn128_bn_shift     bn_silu_128_stream_0 bn_shift      256 bn128_bn_shift.coe}
    {bmg_bn128_in_scale     bn_silu_128_stream_0 input_scale     2 bn128_input_scale.coe}
    {bmg_bn128_wt_scale     bn_silu_128_stream_0 weight_scale    2 bn128_weight_scale.coe}
    {bmg_bn128_out_scale    bn_silu_128_stream_0 output_scale    2 bn128_output_scale.coe}
    {bmg_bn64_bn_scale      bn_silu_stream_0     bn_scale      256 bn64_bn_scale.coe}
    {bmg_bn64_bn_shift      bn_silu_stream_0     bn_shift      256 bn64_bn_shift.coe}
    {bmg_bn64_in_scale      bn_silu_stream_0     input_scale     4 bn64_input_scale.coe}
    {bmg_bn64_wt_scale      bn_silu_stream_0     weight_scale    4 bn64_weight_scale.coe}
    {bmg_bn64_out_scale     bn_silu_stream_0     output_scale    4 bn64_output_scale.coe}
    {bmg_res_x_scale        residual_add_stream_0 x_scale        2 residual_x_scale.coe}
    {bmg_res_fx_scale       residual_add_stream_0 fx_scale       2 residual_fx_scale.coe}
    {bmg_res_out_scale      residual_add_stream_0 output_scale   2 residual_output_scale.coe}
} {
    lassign $spec mem ipname port depth coe
    mk_bram $mem Single_Port_RAM 32 [expr {4 * $depth}] [file join $coe_dir $coe]
    s ${ipname}/${port}_PORTA ${mem}/BRAM_PORTA
}

# --------------------------------------------- conv1x1 / split 의 ap_start
# 이 둘은 s_axilite port=return 이 없어 제어가 핀으로 나온다. 상수 1 로 묶는다.
foreach n {xlconstant_0 xlconstant_2} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 $n]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $c
}
connect_bd_net [get_bd_pins xlconstant_0/dout] [get_bd_pins conv1x1_stream_0/ap_start]
connect_bd_net [get_bd_pins xlconstant_2/dout] [get_bd_pins split_channel_stream_0/ap_start]

# --------------------------------------------------- 제어 버스 (PS -> 7개)
set ctrl_targets {
    concat_channel_stream_0/s_axi_control
    conv3x3_stream_0/s_axi_control
    bn_silu_stream_0/s_axi_control
    residual_add_stream_0/s_axi_control
    bottleneck_router_0/s_axi_control
    axi_dma_0/S_AXI_LITE
    bn_silu_128_stream_0/s_axi_control
}
set i 0
foreach t $ctrl_targets {
    connect_bd_intf_net [get_bd_intf_pins ps8_0_axi_periph/[format "M%02d_AXI" $i]] \
                        [get_bd_intf_pins $t]
    incr i
}

# ------------------------------------------------------------------- 주소
# 원본 XSA 와 동일하게 고정한다 (ps_run_model6.py 를 수정 없이 쓰기 위함).
set space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]
proc ctrl_addr {inst off} {
    global space
    assign_bd_address -offset $off -range 0x00010000 -target_address_space $space \
        [get_bd_addr_segs $inst] -force
}
ctrl_addr concat_channel_stream_0/s_axi_control/Reg 0xA0000000
ctrl_addr conv3x3_stream_0/s_axi_control/Reg        0xA0010000
ctrl_addr bn_silu_stream_0/s_axi_control/Reg        0xA0020000
ctrl_addr residual_add_stream_0/s_axi_control/Reg   0xA0030000
ctrl_addr bottleneck_router_0/s_axi_control/Reg     0xA0040000
ctrl_addr axi_dma_0/S_AXI_LITE/Reg                  0xA0050000
ctrl_addr bn_silu_128_stream_0/s_axi_control/Reg    0xA0070000

# ★ DMA 가 DDR 을 볼 수 있도록 배정 — 원본에 빠져 있던 부분
# DMA 주소폭이 32bit 이므로 4GB 이상인 HP0_DDR_HIGH 는 배정할 수 없다.
# DDR_LOW(0x0~0x7FFF_FFFF, 2GB)만 배정한다. PYNQ 버퍼는 이 영역에 잡힌다.
foreach spc {Data_MM2S Data_S2MM} {
    assign_bd_address -offset 0x00000000 -range 0x80000000 \
        -target_address_space [get_bd_addr_spaces axi_dma_0/$spc] \
        [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force
    catch {
        exclude_bd_addr_seg \
            -target_address_space [get_bd_addr_spaces axi_dma_0/$spc] \
            [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_HIGH]
    }
}
validate_bd_design -force
save_bd_design
write_bd_tcl -force [file join $out_dir design_1_bd.tcl]

generate_target all [get_files -all */design_1.bd]
set wrapper [make_wrapper -files [get_files -all */design_1.bd] -top]
add_files -norecurse $wrapper
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_utilization -hierarchical -file [file join $out_dir impl_utilization.rpt]
report_timing_summary -file [file join $out_dir impl_timing.rpt]
report_drc -file [file join $out_dir impl_drc.rpt]

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force [file join $impl_dir design_1_wrapper.bit] \
    [file join $out_dir ppe_fpga_yoo_fix2.bit]
write_hw_platform -fixed -include_bit -force \
    [file join $out_dir ppe_fpga_yoo_fix2.xsa]
puts "BUILD COMPLETE"
