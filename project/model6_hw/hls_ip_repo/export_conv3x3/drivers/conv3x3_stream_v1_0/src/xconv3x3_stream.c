// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
/***************************** Include Files *********************************/
#include "xconv3x3_stream.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XConv3x3_stream_CfgInitialize(XConv3x3_stream *InstancePtr, XConv3x3_stream_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XConv3x3_stream_Start(XConv3x3_stream *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL) & 0x80;
    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XConv3x3_stream_IsDone(XConv3x3_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XConv3x3_stream_IsIdle(XConv3x3_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XConv3x3_stream_IsReady(XConv3x3_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XConv3x3_stream_EnableAutoRestart(XConv3x3_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XConv3x3_stream_DisableAutoRestart(XConv3x3_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_AP_CTRL, 0);
}

void XConv3x3_stream_Set_layer_id(XConv3x3_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_LAYER_ID_DATA, Data);
}

u32 XConv3x3_stream_Get_layer_id(XConv3x3_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_LAYER_ID_DATA);
    return Data;
}

void XConv3x3_stream_InterruptGlobalEnable(XConv3x3_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_GIE, 1);
}

void XConv3x3_stream_InterruptGlobalDisable(XConv3x3_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_GIE, 0);
}

void XConv3x3_stream_InterruptEnable(XConv3x3_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_IER);
    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_IER, Register | Mask);
}

void XConv3x3_stream_InterruptDisable(XConv3x3_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_IER);
    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_IER, Register & (~Mask));
}

void XConv3x3_stream_InterruptClear(XConv3x3_stream *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XConv3x3_stream_WriteReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_ISR, Mask);
}

u32 XConv3x3_stream_InterruptGetEnabled(XConv3x3_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_IER);
}

u32 XConv3x3_stream_InterruptGetStatus(XConv3x3_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XConv3x3_stream_ReadReg(InstancePtr->Control_BaseAddress, XCONV3X3_STREAM_CONTROL_ADDR_ISR);
}

