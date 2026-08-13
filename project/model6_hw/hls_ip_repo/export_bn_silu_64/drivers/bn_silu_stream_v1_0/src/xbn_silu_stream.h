// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef XBN_SILU_STREAM_H
#define XBN_SILU_STREAM_H

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
#include "xbn_silu_stream_hw.h"

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
} XBn_silu_stream_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XBn_silu_stream;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XBn_silu_stream_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XBn_silu_stream_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XBn_silu_stream_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XBn_silu_stream_ReadReg(BaseAddress, RegOffset) \
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
int XBn_silu_stream_Initialize(XBn_silu_stream *InstancePtr, u16 DeviceId);
XBn_silu_stream_Config* XBn_silu_stream_LookupConfig(u16 DeviceId);
int XBn_silu_stream_CfgInitialize(XBn_silu_stream *InstancePtr, XBn_silu_stream_Config *ConfigPtr);
#else
int XBn_silu_stream_Initialize(XBn_silu_stream *InstancePtr, const char* InstanceName);
int XBn_silu_stream_Release(XBn_silu_stream *InstancePtr);
#endif

void XBn_silu_stream_Start(XBn_silu_stream *InstancePtr);
u32 XBn_silu_stream_IsDone(XBn_silu_stream *InstancePtr);
u32 XBn_silu_stream_IsIdle(XBn_silu_stream *InstancePtr);
u32 XBn_silu_stream_IsReady(XBn_silu_stream *InstancePtr);
void XBn_silu_stream_EnableAutoRestart(XBn_silu_stream *InstancePtr);
void XBn_silu_stream_DisableAutoRestart(XBn_silu_stream *InstancePtr);

void XBn_silu_stream_Set_input_scale(XBn_silu_stream *InstancePtr, u32 Data);
u32 XBn_silu_stream_Get_input_scale(XBn_silu_stream *InstancePtr);
void XBn_silu_stream_Set_weight_scale(XBn_silu_stream *InstancePtr, u32 Data);
u32 XBn_silu_stream_Get_weight_scale(XBn_silu_stream *InstancePtr);
void XBn_silu_stream_Set_output_scale(XBn_silu_stream *InstancePtr, u32 Data);
u32 XBn_silu_stream_Get_output_scale(XBn_silu_stream *InstancePtr);

void XBn_silu_stream_InterruptGlobalEnable(XBn_silu_stream *InstancePtr);
void XBn_silu_stream_InterruptGlobalDisable(XBn_silu_stream *InstancePtr);
void XBn_silu_stream_InterruptEnable(XBn_silu_stream *InstancePtr, u32 Mask);
void XBn_silu_stream_InterruptDisable(XBn_silu_stream *InstancePtr, u32 Mask);
void XBn_silu_stream_InterruptClear(XBn_silu_stream *InstancePtr, u32 Mask);
u32 XBn_silu_stream_InterruptGetEnabled(XBn_silu_stream *InstancePtr);
u32 XBn_silu_stream_InterruptGetStatus(XBn_silu_stream *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif
