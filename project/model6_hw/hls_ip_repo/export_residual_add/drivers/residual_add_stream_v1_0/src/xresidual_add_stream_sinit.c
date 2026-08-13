// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#include "xparameters.h"
#include "xresidual_add_stream.h"

extern XResidual_add_stream_Config XResidual_add_stream_ConfigTable[];

XResidual_add_stream_Config *XResidual_add_stream_LookupConfig(u16 DeviceId) {
	XResidual_add_stream_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XRESIDUAL_ADD_STREAM_NUM_INSTANCES; Index++) {
		if (XResidual_add_stream_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XResidual_add_stream_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XResidual_add_stream_Initialize(XResidual_add_stream *InstancePtr, u16 DeviceId) {
	XResidual_add_stream_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XResidual_add_stream_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XResidual_add_stream_CfgInitialize(InstancePtr, ConfigPtr);
}

#endif

