// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#include "xparameters.h"
#include "xconv3x3_stream.h"

extern XConv3x3_stream_Config XConv3x3_stream_ConfigTable[];

XConv3x3_stream_Config *XConv3x3_stream_LookupConfig(u16 DeviceId) {
	XConv3x3_stream_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XCONV3X3_STREAM_NUM_INSTANCES; Index++) {
		if (XConv3x3_stream_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XConv3x3_stream_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XConv3x3_stream_Initialize(XConv3x3_stream *InstancePtr, u16 DeviceId) {
	XConv3x3_stream_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XConv3x3_stream_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XConv3x3_stream_CfgInitialize(InstancePtr, ConfigPtr);
}

#endif

