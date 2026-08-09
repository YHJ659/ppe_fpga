// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2022.2 (64-bit)
// Tool Version Limit: 2019.12
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// ==============================================================
#ifndef XBOTTLENECK_ROUTER_H
#define XBOTTLENECK_ROUTER_H

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
#include "xbottleneck_router_hw.h"

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
} XBottleneck_router_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XBottleneck_router;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XBottleneck_router_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XBottleneck_router_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XBottleneck_router_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XBottleneck_router_ReadReg(BaseAddress, RegOffset) \
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
int XBottleneck_router_Initialize(XBottleneck_router *InstancePtr, u16 DeviceId);
XBottleneck_router_Config* XBottleneck_router_LookupConfig(u16 DeviceId);
int XBottleneck_router_CfgInitialize(XBottleneck_router *InstancePtr, XBottleneck_router_Config *ConfigPtr);
#else
int XBottleneck_router_Initialize(XBottleneck_router *InstancePtr, const char* InstanceName);
int XBottleneck_router_Release(XBottleneck_router *InstancePtr);
#endif

void XBottleneck_router_Start(XBottleneck_router *InstancePtr);
u32 XBottleneck_router_IsDone(XBottleneck_router *InstancePtr);
u32 XBottleneck_router_IsIdle(XBottleneck_router *InstancePtr);
u32 XBottleneck_router_IsReady(XBottleneck_router *InstancePtr);
void XBottleneck_router_EnableAutoRestart(XBottleneck_router *InstancePtr);
void XBottleneck_router_DisableAutoRestart(XBottleneck_router *InstancePtr);


void XBottleneck_router_InterruptGlobalEnable(XBottleneck_router *InstancePtr);
void XBottleneck_router_InterruptGlobalDisable(XBottleneck_router *InstancePtr);
void XBottleneck_router_InterruptEnable(XBottleneck_router *InstancePtr, u32 Mask);
void XBottleneck_router_InterruptDisable(XBottleneck_router *InstancePtr, u32 Mask);
void XBottleneck_router_InterruptClear(XBottleneck_router *InstancePtr, u32 Mask);
u32 XBottleneck_router_InterruptGetEnabled(XBottleneck_router *InstancePtr);
u32 XBottleneck_router_InterruptGetStatus(XBottleneck_router *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif
