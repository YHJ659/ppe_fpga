// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef XCONV3X3_STREAM_H
#define XCONV3X3_STREAM_H

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
#include "xconv3x3_stream_hw.h"

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
} XConv3x3_stream_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XConv3x3_stream;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XConv3x3_stream_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XConv3x3_stream_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XConv3x3_stream_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XConv3x3_stream_ReadReg(BaseAddress, RegOffset) \
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
int XConv3x3_stream_Initialize(XConv3x3_stream *InstancePtr, u16 DeviceId);
XConv3x3_stream_Config* XConv3x3_stream_LookupConfig(u16 DeviceId);
int XConv3x3_stream_CfgInitialize(XConv3x3_stream *InstancePtr, XConv3x3_stream_Config *ConfigPtr);
#else
int XConv3x3_stream_Initialize(XConv3x3_stream *InstancePtr, const char* InstanceName);
int XConv3x3_stream_Release(XConv3x3_stream *InstancePtr);
#endif

void XConv3x3_stream_Start(XConv3x3_stream *InstancePtr);
u32 XConv3x3_stream_IsDone(XConv3x3_stream *InstancePtr);
u32 XConv3x3_stream_IsIdle(XConv3x3_stream *InstancePtr);
u32 XConv3x3_stream_IsReady(XConv3x3_stream *InstancePtr);
void XConv3x3_stream_EnableAutoRestart(XConv3x3_stream *InstancePtr);
void XConv3x3_stream_DisableAutoRestart(XConv3x3_stream *InstancePtr);

void XConv3x3_stream_Set_layer_id(XConv3x3_stream *InstancePtr, u32 Data);
u32 XConv3x3_stream_Get_layer_id(XConv3x3_stream *InstancePtr);

void XConv3x3_stream_InterruptGlobalEnable(XConv3x3_stream *InstancePtr);
void XConv3x3_stream_InterruptGlobalDisable(XConv3x3_stream *InstancePtr);
void XConv3x3_stream_InterruptEnable(XConv3x3_stream *InstancePtr, u32 Mask);
void XConv3x3_stream_InterruptDisable(XConv3x3_stream *InstancePtr, u32 Mask);
void XConv3x3_stream_InterruptClear(XConv3x3_stream *InstancePtr, u32 Mask);
u32 XConv3x3_stream_InterruptGetEnabled(XConv3x3_stream *InstancePtr);
u32 XConv3x3_stream_InterruptGetStatus(XConv3x3_stream *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif
