// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef XCONCAT_CHANNEL_STREAM_H
#define XCONCAT_CHANNEL_STREAM_H

#ifdef __cplusplus
extern "C" {
#endif

/***************************** Include Files *********************************/
#ifndef __linux__
#include "xil_types.h"
#include "xil_assert.h"
#include "xstatus.h"
#include "xil_io.h"
#else
#include <stdint.h>
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stddef.h>
#endif
#include "xconcat_channel_stream_hw.h"

/**************************** Type Definitions ******************************/
#ifdef __linux__
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#else
typedef struct {
    u16 DeviceId;
    u64 Control_BaseAddress;
} XConcat_channel_stream_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XConcat_channel_stream;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XConcat_channel_stream_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XConcat_channel_stream_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XConcat_channel_stream_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XConcat_channel_stream_ReadReg(BaseAddress, RegOffset) \
    *(volatile u32*)((BaseAddress) + (RegOffset))

#define Xil_AssertVoid(expr)    assert(expr)
#define Xil_AssertNonvoid(expr) assert(expr)

#define XST_SUCCESS             0
#define XST_DEVICE_NOT_FOUND    2
#define XST_OPEN_DEVICE_FAILED  3
#define XIL_COMPONENT_IS_READY  1
#endif

/************************** Function Prototypes *****************************/
#ifndef __linux__
int XConcat_channel_stream_Initialize(XConcat_channel_stream *InstancePtr, u16 DeviceId);
XConcat_channel_stream_Config* XConcat_channel_stream_LookupConfig(u16 DeviceId);
int XConcat_channel_stream_CfgInitialize(XConcat_channel_stream *InstancePtr, XConcat_channel_stream_Config *ConfigPtr);
#else
int XConcat_channel_stream_Initialize(XConcat_channel_stream *InstancePtr, const char* InstanceName);
int XConcat_channel_stream_Release(XConcat_channel_stream *InstancePtr);
#endif

void XConcat_channel_stream_Start(XConcat_channel_stream *InstancePtr);
u32 XConcat_channel_stream_IsDone(XConcat_channel_stream *InstancePtr);
u32 XConcat_channel_stream_IsIdle(XConcat_channel_stream *InstancePtr);
u32 XConcat_channel_stream_IsReady(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_EnableAutoRestart(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_DisableAutoRestart(XConcat_channel_stream *InstancePtr);

void XConcat_channel_stream_Set_scale0(XConcat_channel_stream *InstancePtr, u32 Data);
u32 XConcat_channel_stream_Get_scale0(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_Set_scale1(XConcat_channel_stream *InstancePtr, u32 Data);
u32 XConcat_channel_stream_Get_scale1(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_Set_scale2(XConcat_channel_stream *InstancePtr, u32 Data);
u32 XConcat_channel_stream_Get_scale2(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_Set_scale3(XConcat_channel_stream *InstancePtr, u32 Data);
u32 XConcat_channel_stream_Get_scale3(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_Set_output_scale(XConcat_channel_stream *InstancePtr, u32 Data);
u32 XConcat_channel_stream_Get_output_scale(XConcat_channel_stream *InstancePtr);

void XConcat_channel_stream_InterruptGlobalEnable(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_InterruptGlobalDisable(XConcat_channel_stream *InstancePtr);
void XConcat_channel_stream_InterruptEnable(XConcat_channel_stream *InstancePtr, u32 Mask);
void XConcat_channel_stream_InterruptDisable(XConcat_channel_stream *InstancePtr, u32 Mask);
void XConcat_channel_stream_InterruptClear(XConcat_channel_stream *InstancePtr, u32 Mask);
u32 XConcat_channel_stream_InterruptGetEnabled(XConcat_channel_stream *InstancePtr);
u32 XConcat_channel_stream_InterruptGetStatus(XConcat_channel_stream *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif
