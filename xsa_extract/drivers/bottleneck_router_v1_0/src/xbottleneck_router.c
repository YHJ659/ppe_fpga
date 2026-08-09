// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
/***************************** Include Files *********************************/
#include "xbottleneck_router.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XBottleneck_router_CfgInitialize(XBottleneck_router *InstancePtr, XBottleneck_router_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XBottleneck_router_Start(XBottleneck_router *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL) & 0x80;
    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XBottleneck_router_IsDone(XBottleneck_router *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XBottleneck_router_IsIdle(XBottleneck_router *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XBottleneck_router_IsReady(XBottleneck_router *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XBottleneck_router_EnableAutoRestart(XBottleneck_router *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XBottleneck_router_DisableAutoRestart(XBottleneck_router *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_AP_CTRL, 0);
}

void XBottleneck_router_InterruptGlobalEnable(XBottleneck_router *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_GIE, 1);
}

void XBottleneck_router_InterruptGlobalDisable(XBottleneck_router *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_GIE, 0);
}

void XBottleneck_router_InterruptEnable(XBottleneck_router *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_IER);
    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_IER, Register | Mask);
}

void XBottleneck_router_InterruptDisable(XBottleneck_router *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_IER);
    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_IER, Register & (~Mask));
}

void XBottleneck_router_InterruptClear(XBottleneck_router *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XBottleneck_router_WriteReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_ISR, Mask);
}

u32 XBottleneck_router_InterruptGetEnabled(XBottleneck_router *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_IER);
}

u32 XBottleneck_router_InterruptGetStatus(XBottleneck_router *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XBottleneck_router_ReadReg(InstancePtr->Control_BaseAddress, XBOTTLENECK_ROUTER_CONTROL_ADDR_ISR);
}

