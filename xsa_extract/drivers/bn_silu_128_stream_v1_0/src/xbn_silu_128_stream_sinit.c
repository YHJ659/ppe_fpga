// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#include "xparameters.h"
#include "xbn_silu_128_stream.h"

extern XBn_silu_128_stream_Config XBn_silu_128_stream_ConfigTable[];

XBn_silu_128_stream_Config *XBn_silu_128_stream_LookupConfig(u16 DeviceId) {
	XBn_silu_128_stream_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XBN_SILU_128_STREAM_NUM_INSTANCES; Index++) {
		if (XBn_silu_128_stream_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XBn_silu_128_stream_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XBn_silu_128_stream_Initialize(XBn_silu_128_stream *InstancePtr, u16 DeviceId) {
	XBn_silu_128_stream_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XBn_silu_128_stream_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XBn_silu_128_stream_CfgInitialize(InstancePtr, ConfigPtr);
}

#endif

