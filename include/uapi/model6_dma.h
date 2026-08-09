#ifndef MODEL6_DMA_UAPI_H
#define MODEL6_DMA_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define MODEL6_DMA_INPUT_BYTES  204800U
#define MODEL6_DMA_OUTPUT_BYTES 409600U

struct model6_dma_layout {
    __u32 input_bytes;
    __u32 output_bytes;
    __u64 input_mmap_offset;
    __u64 output_mmap_offset;
};

struct model6_dma_wait {
    __u32 timeout_ms;
    __s32 result;
};

struct model6_dma_status {
    __u32 busy;
    __s32 result;
};

#define MODEL6_DMA_IOC_MAGIC 'M'
#define MODEL6_DMA_IOC_ALLOC       _IOR(MODEL6_DMA_IOC_MAGIC, 0x00, struct model6_dma_layout)
#define MODEL6_DMA_IOC_PROGRAM     _IO(MODEL6_DMA_IOC_MAGIC,  0x01)
#define MODEL6_DMA_IOC_START       _IO(MODEL6_DMA_IOC_MAGIC,  0x02)
#define MODEL6_DMA_IOC_WAIT        _IOWR(MODEL6_DMA_IOC_MAGIC, 0x03, struct model6_dma_wait)
#define MODEL6_DMA_IOC_STATUS      _IOR(MODEL6_DMA_IOC_MAGIC, 0x04, struct model6_dma_status)
#define MODEL6_DMA_IOC_RESET       _IO(MODEL6_DMA_IOC_MAGIC,  0x05)

#endif
