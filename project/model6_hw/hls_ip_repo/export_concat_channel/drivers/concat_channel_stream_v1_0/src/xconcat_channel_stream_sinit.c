// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#include "xparameters.h"
#include "xconcat_channel_stream.h"

extern XConcat_channel_stream_Config XConcat_channel_stream_ConfigTable[];

XConcat_channel_stream_Config *XConcat_channel_stream_LookupConfig(u16 DeviceId) {
	XConcat_channel_stream_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XCONCAT_CHANNEL_STREAM_NUM_INSTANCES; Index++) {
		if (XConcat_channel_stream_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XConcat_channel_stream_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XConcat_channel_stream_Initialize(XConcat_channel_stream *InstancePtr, u16 DeviceId) {
	XConcat_channel_stream_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XConcat_channel_stream_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XConcat_channel_stream_CfgInitialize(InstancePtr, ConfigPtr);
}

#endif

