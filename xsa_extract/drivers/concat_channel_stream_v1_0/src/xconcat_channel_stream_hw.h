// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
// control
// 0x00 : Control signals
//        bit 0  - ap_start (Read/Write/COH)
//        bit 1  - ap_done (Read/COR)
//        bit 2  - ap_idle (Read)
//        bit 3  - ap_ready (Read/COR)
//        bit 7  - auto_restart (Read/Write)
//        bit 9  - interrupt (Read)
//        others - reserved
// 0x04 : Global Interrupt Enable Register
//        bit 0  - Global Interrupt Enable (Read/Write)
//        others - reserved
// 0x08 : IP Interrupt Enable Register (Read/Write)
//        bit 0 - enable ap_done interrupt (Read/Write)
//        bit 1 - enable ap_ready interrupt (Read/Write)
//        others - reserved
// 0x0c : IP Interrupt Status Register (Read/TOW)
//        bit 0 - ap_done (Read/TOW)
//        bit 1 - ap_ready (Read/TOW)
//        others - reserved
// 0x10 : Data signal of scale0
//        bit 31~0 - scale0[31:0] (Read/Write)
// 0x14 : reserved
// 0x18 : Data signal of scale1
//        bit 31~0 - scale1[31:0] (Read/Write)
// 0x1c : reserved
// 0x20 : Data signal of scale2
//        bit 31~0 - scale2[31:0] (Read/Write)
// 0x24 : reserved
// 0x28 : Data signal of scale3
//        bit 31~0 - scale3[31:0] (Read/Write)
// 0x2c : reserved
// 0x30 : Data signal of output_scale
//        bit 31~0 - output_scale[31:0] (Read/Write)
// 0x34 : reserved
// (SC = Self Clear, COR = Clear on Read, TOW = Toggle on Write, COH = Clear on Handshake)

#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL           0x00
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_GIE               0x04
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_IER               0x08
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_ISR               0x0c
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE0_DATA       0x10
#define XCONCAT_CHANNEL_STREAM_CONTROL_BITS_SCALE0_DATA       32
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE1_DATA       0x18
#define XCONCAT_CHANNEL_STREAM_CONTROL_BITS_SCALE1_DATA       32
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE2_DATA       0x20
#define XCONCAT_CHANNEL_STREAM_CONTROL_BITS_SCALE2_DATA       32
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE3_DATA       0x28
#define XCONCAT_CHANNEL_STREAM_CONTROL_BITS_SCALE3_DATA       32
#define XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA 0x30
#define XCONCAT_CHANNEL_STREAM_CONTROL_BITS_OUTPUT_SCALE_DATA 32

