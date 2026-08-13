#include "xparameters.h"
#include "xaxidma.h"
#include "xaxis_passthrough.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

#define WORD_COUNT 256U
#define BYTE_COUNT (WORD_COUNT * sizeof(u32))
#define TIMEOUT_COUNT 100000000U

static u32 TxBuffer[WORD_COUNT] __attribute__((aligned(64)));
static u32 RxBuffer[WORD_COUNT] __attribute__((aligned(64)));

static int wait_for_dma(XAxiDma *Dma, int Direction, const char *Name)
{
    u32 Timeout = TIMEOUT_COUNT;

    while (XAxiDma_Busy(Dma, Direction)) {
        if (--Timeout == 0U) {
            xil_printf("ERROR: %s timeout\r\n", Name);
            return XST_FAILURE;
        }
    }

    return XST_SUCCESS;
}

int main(void)
{
    XAxiDma Dma;
    XAxiDma_Config *DmaConfig;
    XAxis_passthrough Passthrough;
    int Status;
    u32 Index;
    u32 ErrorCount = 0U;

    xil_printf("\r\nPPE AXI DMA passthrough test\r\n");
    xil_printf("Transfer size: %u bytes\r\n", (unsigned int)BYTE_COUNT);

    xil_printf("STEP 1: DMA config lookup\r\n");
    DmaConfig = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_DEVICE_ID);
    if (DmaConfig == NULL) {
        xil_printf("ERROR: DMA configuration not found\r\n");
        return XST_FAILURE;
    }
    xil_printf("STEP 2: DMA config found at 0x%08x\r\n",
               (unsigned int)DmaConfig->BaseAddr);

    xil_printf("STEP 3: DMA initialize\r\n");
    Status = XAxiDma_CfgInitialize(&Dma, DmaConfig);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: DMA initialization failed: %d\r\n", Status);
        return XST_FAILURE;
    }
    xil_printf("STEP 4: DMA initialized\r\n");

    xil_printf("STEP 5: Check DMA mode\r\n");
    if (XAxiDma_HasSg(&Dma)) {
        xil_printf("ERROR: DMA is configured for scatter-gather\r\n");
        return XST_FAILURE;
    }
    xil_printf("STEP 6: Simple DMA confirmed\r\n");

    XAxiDma_IntrDisable(&Dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&Dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    xil_printf("STEP 7: DMA interrupts disabled\r\n");

    xil_printf("STEP 8: Passthrough initialize\r\n");
    Status = XAxis_passthrough_Initialize(
        &Passthrough, XPAR_AXIS_PASSTHROUGH_0_DEVICE_ID);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: passthrough initialization failed: %d\r\n", Status);
        return XST_FAILURE;
    }
    xil_printf("STEP 9: Passthrough initialized\r\n");

    for (Index = 0U; Index < WORD_COUNT; ++Index) {
        TxBuffer[Index] = 0xA5000000U ^ (Index * 0x10203U);
        RxBuffer[Index] = 0U;
    }

    Xil_DCacheFlushRange((UINTPTR)TxBuffer, BYTE_COUNT);
    Xil_DCacheFlushRange((UINTPTR)RxBuffer, BYTE_COUNT);

    Status = XAxiDma_SimpleTransfer(
        &Dma, (UINTPTR)RxBuffer, BYTE_COUNT, XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM start failed: %d\r\n", Status);
        return XST_FAILURE;
    }

    XAxis_passthrough_Start(&Passthrough);

    Status = XAxiDma_SimpleTransfer(
        &Dma, (UINTPTR)TxBuffer, BYTE_COUNT, XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S start failed: %d\r\n", Status);
        return XST_FAILURE;
    }

    Status = wait_for_dma(&Dma, XAXIDMA_DMA_TO_DEVICE, "MM2S");
    if (Status != XST_SUCCESS) {
        return Status;
    }

    Status = wait_for_dma(&Dma, XAXIDMA_DEVICE_TO_DMA, "S2MM");
    if (Status != XST_SUCCESS) {
        return Status;
    }

    if (!XAxis_passthrough_IsDone(&Passthrough)) {
        xil_printf("ERROR: passthrough did not assert ap_done\r\n");
        return XST_FAILURE;
    }

    Xil_DCacheInvalidateRange((UINTPTR)RxBuffer, BYTE_COUNT);

    for (Index = 0U; Index < WORD_COUNT; ++Index) {
        if (RxBuffer[Index] != TxBuffer[Index]) {
            if (ErrorCount < 8U) {
                xil_printf(
                    "Mismatch[%u]: TX=0x%08x RX=0x%08x\r\n",
                    (unsigned int)Index,
                    (unsigned int)TxBuffer[Index],
                    (unsigned int)RxBuffer[Index]);
            }
            ++ErrorCount;
        }
    }

    if (ErrorCount != 0U) {
        xil_printf("FAIL: %u mismatches\r\n", (unsigned int)ErrorCount);
        return XST_FAILURE;
    }

    xil_printf("PASS: DMA AXI4-Stream loopback matched all %u words\r\n",
               (unsigned int)WORD_COUNT);
    return XST_SUCCESS;
}
