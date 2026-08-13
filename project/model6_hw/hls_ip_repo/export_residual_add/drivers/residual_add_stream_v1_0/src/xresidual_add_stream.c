// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
/***************************** Include Files *********************************/
#include "xresidual_add_stream.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XResidual_add_stream_CfgInitialize(XResidual_add_stream *InstancePtr, XResidual_add_stream_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XResidual_add_stream_Start(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL) & 0x80;
    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XResidual_add_stream_IsDone(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XResidual_add_stream_IsIdle(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XResidual_add_stream_IsReady(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XResidual_add_stream_EnableAutoRestart(XResidual_add_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XResidual_add_stream_DisableAutoRestart(XResidual_add_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_AP_CTRL, 0);
}

void XResidual_add_stream_Set_x_scale(XResidual_add_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_X_SCALE_DATA, Data);
}

u32 XResidual_add_stream_Get_x_scale(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_X_SCALE_DATA);
    return Data;
}

void XResidual_add_stream_Set_fx_scale(XResidual_add_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_FX_SCALE_DATA, Data);
}

u32 XResidual_add_stream_Get_fx_scale(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_FX_SCALE_DATA);
    return Data;
}

void XResidual_add_stream_Set_output_scale(XResidual_add_stream *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA, Data);
}

u32 XResidual_add_stream_Get_output_scale(XResidual_add_stream *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_OUTPUT_SCALE_DATA);
    return Data;
}

void XResidual_add_stream_InterruptGlobalEnable(XResidual_add_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_GIE, 1);
}

void XResidual_add_stream_InterruptGlobalDisable(XResidual_add_stream *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_GIE, 0);
}

void XResidual_add_stream_InterruptEnable(XResidual_add_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_IER);
    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_IER, Register | Mask);
}

void XResidual_add_stream_InterruptDisable(XResidual_add_stream *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_IER);
    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_IER, Register & (~Mask));
}

void XResidual_add_stream_InterruptClear(XResidual_add_stream *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XResidual_add_stream_WriteReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_ISR, Mask);
}

u32 XResidual_add_stream_InterruptGetEnabled(XResidual_add_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_IER);
}

u32 XResidual_add_stream_InterruptGetStatus(XResidual_add_stream *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XResidual_add_stream_ReadReg(InstancePtr->Control_BaseAddress, XRESIDUAL_ADD_STREAM_CONTROL_ADDR_ISR);
}

