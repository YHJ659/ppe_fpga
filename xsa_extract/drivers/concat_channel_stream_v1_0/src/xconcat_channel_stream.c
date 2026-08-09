// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
/***************************** Include Files *********************************/
#include "xconcat_channel_stream.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XConcat_channel_stream_CfgInitialize(XConcat_channel_stream *InstancePtr, XConcat_channel_stream_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XConcat_channel_stream_Start(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL) & 0x80;
    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XConcat_channel_stream_IsDone(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XConcat_channel_stream_IsIdle(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XConcat_channel_stream_IsReady(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XConcat_channel_stream_EnableAutoRestart(XConcat_channel_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XConcat_channel_stream_DisableAutoRestart(XConcat_channel_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_AP_CTRL, 0);
}

void XConcat_channel_stream_Set_scale0(XConcat_channel_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE0_DATA, Data);
}

u32 XConcat_channel_stream_Get_scale0(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE0_DATA);
    return Data;
}

void XConcat_channel_stream_Set_scale1(XConcat_channel_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE1_DATA, Data);
}

u32 XConcat_channel_stream_Get_scale1(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE1_DATA);
    return Data;
}

void XConcat_channel_stream_Set_scale2(XConcat_channel_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE2_DATA, Data);
}

u32 XConcat_channel_stream_Get_scale2(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE2_DATA);
    return Data;
}

void XConcat_channel_stream_Set_scale3(XConcat_channel_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE3_DATA, Data);
}

u32 XConcat_channel_stream_Get_scale3(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_SCALE3_DATA);
    return Data;
}

void XConcat_channel_stream_Set_output_scale(XConcat_channel_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA, Data);
}

u32 XConcat_channel_stream_Get_output_scale(XConcat_channel_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA);
    return Data;
}

void XConcat_channel_stream_InterruptGlobalEnable(XConcat_channel_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_GIE, 1);
}

void XConcat_channel_stream_InterruptGlobalDisable(XConcat_channel_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_GIE, 0);
}

void XConcat_channel_stream_InterruptEnable(XConcat_channel_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_IER);
    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_IER, Register | Mask);
}

void XConcat_channel_stream_InterruptDisable(XConcat_channel_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_IER);
    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_IER, Register & (~Mask));
}

void XConcat_channel_stream_InterruptClear(XConcat_channel_stream *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConcat_channel_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_ISR, Mask);
}

u32 XConcat_channel_stream_InterruptGetEnabled(XConcat_channel_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_IER);
}

u32 XConcat_channel_stream_InterruptGetStatus(XConcat_channel_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XConcat_channel_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONCAT_CHANNEL_STREAM_CONTROL_ADDR_ISR);
}

