// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef XRESIDUAL_ADD_STREAM_H
#define XRESIDUAL_ADD_STREAM_H

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
#include "xresidual_add_stream_hw.h"

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
} XResidual_add_stream_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XResidual_add_stream;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XResidual_add_stream_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XResidual_add_stream_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XResidual_add_stream_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XResidual_add_stream_ReadReg(BaseAddress, RegOffset) \
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
int XResidual_add_stream_Initialize(XResidual_add_stream *InstancePtr, u16 DeviceId);
XResidual_add_stream_Config* XResidual_add_stream_LookupConfig(u16 DeviceId);
int XResidual_add_stream_CfgInitialize(XResidual_add_stream *InstancePtr, XResidual_add_stream_Config *ConfigPtr);
#else
int XResidual_add_stream_Initialize(XResidual_add_stream *InstancePtr, const char* InstanceName);
int XResidual_add_stream_Release(XResidual_add_stream *InstancePtr);
#endif

void XResidual_add_stream_Start(XResidual_add_stream *InstancePtr);
u32 XResidual_add_stream_IsDone(XResidual_add_stream *InstancePtr);
u32 XResidual_add_stream_IsIdle(XResidual_add_stream *InstancePtr);
u32 XResidual_add_stream_IsReady(XResidual_add_stream *InstancePtr);
void XResidual_add_stream_EnableAutoRestart(XResidual_add_stream *InstancePtr);
void XResidual_add_stream_DisableAutoRestart(XResidual_add_stream *InstancePtr);

void XResidual_add_stream_Set_x_scale(XResidual_add_stream *InstancePtr, u32 Data);
u32 XResidual_add_stream_Get_x_scale(XResidual_add_stream *InstancePtr);
void XResidual_add_stream_Set_fx_scale(XResidual_add_stream *InstancePtr, u32 Data);
u32 XResidual_add_stream_Get_fx_scale(XResidual_add_stream *InstancePtr);
void XResidual_add_stream_Set_output_scale(XResidual_add_stream *InstancePtr, u32 Data);
u32 XResidual_add_stream_Get_output_scale(XResidual_add_stream *InstancePtr);

void XResidual_add_stream_InterruptGlobalEnable(XResidual_add_stream *InstancePtr);
void XResidual_add_stream_InterruptGlobalDisable(XResidual_add_stream *InstancePtr);
void XResidual_add_stream_InterruptEnable(XResidual_add_stream *InstancePtr, u32 Mask);
void XResidual_add_stream_InterruptDisable(XResidual_add_stream *InstancePtr, u32 Mask);
void XResidual_add_stream_InterruptClear(XResidual_add_stream *InstancePtr, u32 Mask);
u32 XResidual_add_stream_InterruptGetEnabled(XResidual_add_stream *InstancePtr);
u32 XResidual_add_stream_InterruptGetStatus(XResidual_add_stream *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif
