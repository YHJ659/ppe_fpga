#include "hw_driver.h"
#include "model6_dma.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

struct model6_hw {
    int fd;
    void *input;
    void *output;
    struct model6_dma_layout layout;
};

struct model6_hw *model6_create(void)
{
    struct model6_hw *hw = calloc(1, sizeof(*hw));
    if (!hw)
        return NULL;
    hw->fd = -1;
    hw->fd = open("/dev/model6_dma", O_RDWR | O_CLOEXEC);
    if (hw->fd < 0)
        goto error;
    if (ioctl(hw->fd, MODEL6_DMA_IOC_ALLOC, &hw->layout) < 0)
        goto error;
    if (hw->layout.input_bytes != MODEL6_DMA_INPUT_BYTES ||
        hw->layout.output_bytes != MODEL6_DMA_OUTPUT_BYTES) {
        errno = EPROTO;
        goto error;
    }
    hw->input = mmap(NULL, hw->layout.input_bytes, PROT_READ | PROT_WRITE,
                     MAP_SHARED, hw->fd, (off_t)hw->layout.input_mmap_offset);
    if (hw->input == MAP_FAILED) {
        hw->input = NULL;
        goto error;
    }
    hw->output = mmap(NULL, hw->layout.output_bytes, PROT_READ | PROT_WRITE,
                      MAP_SHARED, hw->fd, (off_t)hw->layout.output_mmap_offset);
    if (hw->output == MAP_FAILED) {
        hw->output = NULL;
        goto error;
    }
    if (ioctl(hw->fd, MODEL6_DMA_IOC_PROGRAM) < 0)
        goto error;
    return hw;

error:
    model6_destroy(hw);
    return NULL;
}

void model6_destroy(struct model6_hw *hw)
{
    if (!hw)
        return;
    if (hw->input)
        munmap(hw->input, hw->layout.input_bytes);
    if (hw->output)
        munmap(hw->output, hw->layout.output_bytes);
    if (hw->fd >= 0)
        close(hw->fd);
    free(hw);
}

int model6_run(struct model6_hw *hw, const int8_t *input, int8_t *output,
               unsigned int timeout_ms)
{
    struct model6_dma_wait wait = { .timeout_ms = timeout_ms, .result = 0 };

    if (!hw || !input || !output)
        return -EINVAL;
    memcpy(hw->input, input, MODEL6_DMA_INPUT_BYTES);
    if (ioctl(hw->fd, MODEL6_DMA_IOC_START) < 0)
        return -errno;
    if (ioctl(hw->fd, MODEL6_DMA_IOC_WAIT, &wait) < 0) {
        int err = errno;
        fprintf(stderr, "MODEL6: IOC_WAIT failed errno=%d\n", err);
        return -err;
    }
    if (wait.result) {
        fprintf(stderr, "MODEL6: IOC_WAIT succeeded result=%d\n",
                wait.result);
        return wait.result;
    }
    memcpy(output, hw->output, MODEL6_DMA_OUTPUT_BYTES);
    return 0;
}
