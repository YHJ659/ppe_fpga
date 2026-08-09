// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#include "xparameters.h"
#include "xbottleneck_router.h"

extern XBottleneck_router_Config XBottleneck_router_ConfigTable[];

XBottleneck_router_Config *XBottleneck_router_LookupConfig(u16 DeviceId) {
	XBottleneck_router_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XBOTTLENECK_ROUTER_NUM_INSTANCES; Index++) {
		if (XBottleneck_router_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XBottleneck_router_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XBottleneck_router_Initialize(XBottleneck_router *InstancePtr, u16 DeviceId) {
	XBottleneck_router_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XBottleneck_router_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XBottleneck_router_CfgInitialize(InstancePtr, ConfigPtr);
}

#endif

