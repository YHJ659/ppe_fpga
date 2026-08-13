// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
/***************************** Include Files *********************************/
#include "xbn_silu_128_stream.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XBn_silu_128_stream_CfgInitialize(XBn_silu_128_stream *InstancePtr, XBn_silu_128_stream_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XBn_silu_128_stream_Start(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL) & 0x80;
    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XBn_silu_128_stream_IsDone(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XBn_silu_128_stream_IsIdle(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XBn_silu_128_stream_IsReady(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XBn_silu_128_stream_EnableAutoRestart(XBn_silu_128_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XBn_silu_128_stream_DisableAutoRestart(XBn_silu_128_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_AP_CTRL, 0);
}

void XBn_silu_128_stream_Set_input_scale(XBn_silu_128_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_INPUT_SCALE_DATA, Data);
}

u32 XBn_silu_128_stream_Get_input_scale(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_INPUT_SCALE_DATA);
    return Data;
}

void XBn_silu_128_stream_Set_weight_scale(XBn_silu_128_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_WEIGHT_SCALE_DATA, Data);
}

u32 XBn_silu_128_stream_Get_weight_scale(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_WEIGHT_SCALE_DATA);
    return Data;
}

void XBn_silu_128_stream_Set_output_scale(XBn_silu_128_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA, Data);
}

u32 XBn_silu_128_stream_Get_output_scale(XBn_silu_128_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA);
    return Data;
}

void XBn_silu_128_stream_InterruptGlobalEnable(XBn_silu_128_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_GIE, 1);
}

void XBn_silu_128_stream_InterruptGlobalDisable(XBn_silu_128_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_GIE, 0);
}

void XBn_silu_128_stream_InterruptEnable(XBn_silu_128_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_IER);
    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_IER, Register | Mask);
}

void XBn_silu_128_stream_InterruptDisable(XBn_silu_128_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_IER);
    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_IER, Register & (~Mask));
}

void XBn_silu_128_stream_InterruptClear(XBn_silu_128_stream *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBn_silu_128_stream_WriteReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_ISR, Mask);
}

u32 XBn_silu_128_stream_InterruptGetEnabled(XBn_silu_128_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_IER);
}

u32 XBn_silu_128_stream_InterruptGetStatus(XBn_silu_128_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XBn_silu_128_stream_ReadReg(InstancePtr->Control_BaseAddress, XBN_SILU_128_STREAM_CONTROL_ADDR_ISR);
}

