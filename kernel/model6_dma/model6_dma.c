// SPDX-License-Identifier: GPL-2.0-only
#include <linux/bitops.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>

#include "model6_dma.h"

#define MODEL6_REG_WINDOW             0x80000
#define MODEL6_CONCAT_OFF              0x00000
#define MODEL6_CONV3X3_OFF             0x10000
#define MODEL6_BN_SILU_OFF             0x20000
#define MODEL6_RESIDUAL_OFF            0x30000
#define MODEL6_ROUTER_OFF              0x40000
#define MODEL6_DMA_OFF                 0x50000
#define MODEL6_BN_SILU_128_OFF         0x70000

#define HLS_AP_CTRL                    0x00
#define HLS_AP_START                   BIT(0)
#define CONCAT_SCALE0                  0x10
#define CONCAT_SCALE1                  0x18
#define CONCAT_SCALE2                  0x20
#define CONCAT_SCALE3                  0x28
#define CONCAT_OUTPUT_SCALE            0x30

/* IEEE-754 encodings from design/model6_params.h. */
#define SCALE_CV1OUT_BITS              0x3d5b2c7b
#define SCALE_Y2_BITS                  0x3d1e5213
#define SCALE_Y3_BITS                  0x3d843192
#define SCALE_CAT_BITS                 0x3d62a7a3

#define MM2S_DMACR                     0x00
#define MM2S_DMASR                     0x04
#define MM2S_SA                        0x18
#define MM2S_SA_MSB                    0x1C
#define MM2S_LENGTH                    0x28
#define S2MM_DMACR                     0x30
#define S2MM_DMASR                     0x34
#define S2MM_DA                        0x48
#define S2MM_DA_MSB                    0x4C
#define S2MM_LENGTH                    0x58
#define DMA_RUNSTOP                    BIT(0)
#define DMA_RESET                      BIT(2)
#define DMA_IDLE                       BIT(1)
#define DMA_IOC                        BIT(12)
#define DMA_ERROR                      GENMASK(6, 4)
#define DMA_DONE                       (DMA_IDLE | DMA_IOC)
#define DMA_LENGTH_MAX                 ((1U << 26) - 1U)
#define DMA_POLL_US                    50
#define DMA_TIMEOUT_US                 2000000

#define HLS_AUTO_RESTART               BIT(7)

/* These PS-side settings are also made by the known-good UIO runner. */
#define AFI_FS_ADDR                    0xFD615000
#define AFI_FS_VALUE_MASK              0x00000F00
#define AFI_FS_VALUE                   0x00000A00
#define AFIFM_HP0_ADDR                 0xFD380000
#define AFIFM_RDCTRL                   0x00
#define AFIFM_WRCTRL                   0x14

struct model6_dma_dev {
    struct device *dev;
    void __iomem *regs;
    void __iomem *afi_fs;
    void __iomem *afifm_hp0;
    void *input_cpu;
    dma_addr_t input_dma;
    void *output_cpu;
    dma_addr_t output_dma;
    struct miscdevice miscdev;
    struct mutex lock;
    struct completion complete;
    struct work_struct work;
    bool busy;
    bool hls_started;
    int result;
};

static inline void __iomem *m6_ip(struct model6_dma_dev *m6, u32 offset)
{
    return m6->regs + offset;
}

static int m6_reset_locked(struct model6_dma_dev *m6)
{
    void __iomem *dma = m6_ip(m6, MODEL6_DMA_OFF);

    writel(DMA_RESET, dma + MM2S_DMACR);
    usleep_range(2000, 2500);
    return 0;
}

static void m6_program_locked(struct model6_dma_dev *m6)
{
    void __iomem *concat = m6_ip(m6, MODEL6_CONCAT_OFF);

    writel(SCALE_CV1OUT_BITS, concat + CONCAT_SCALE0);
    writel(SCALE_CV1OUT_BITS, concat + CONCAT_SCALE1);
    writel(SCALE_Y2_BITS, concat + CONCAT_SCALE2);
    writel(SCALE_Y3_BITS, concat + CONCAT_SCALE3);
    writel(SCALE_CAT_BITS, concat + CONCAT_OUTPUT_SCALE);
}

static void m6_start_hls_locked(struct model6_dma_dev *m6)
{
    u32 control = HLS_AUTO_RESTART | HLS_AP_START;

    writel(control, m6_ip(m6, MODEL6_CONCAT_OFF) + HLS_AP_CTRL);
    writel(control, m6_ip(m6, MODEL6_CONV3X3_OFF) + HLS_AP_CTRL);
    writel(control, m6_ip(m6, MODEL6_BN_SILU_OFF) + HLS_AP_CTRL);
    writel(control, m6_ip(m6, MODEL6_RESIDUAL_OFF) + HLS_AP_CTRL);
    writel(control, m6_ip(m6, MODEL6_ROUTER_OFF) + HLS_AP_CTRL);
    writel(control, m6_ip(m6, MODEL6_BN_SILU_128_OFF) + HLS_AP_CTRL);
}

static int m6_start_mm2s(struct model6_dma_dev *m6, dma_addr_t address,
                         u32 bytes)
{
    void __iomem *dma = m6_ip(m6, MODEL6_DMA_OFF);

    if (!bytes || bytes > DMA_LENGTH_MAX)
        return -EINVAL;
    writel(lower_32_bits(address), dma + MM2S_SA);
    writel(0, dma + MM2S_SA_MSB);
    writel(bytes, dma + MM2S_LENGTH);
    return 0;
}

static int m6_start_s2mm(struct model6_dma_dev *m6, dma_addr_t address,
                         u32 bytes)
{
    void __iomem *dma = m6_ip(m6, MODEL6_DMA_OFF);

    if (!bytes || bytes > DMA_LENGTH_MAX)
        return -EINVAL;
    writel(lower_32_bits(address), dma + S2MM_DA);
    writel(0, dma + S2MM_DA_MSB);
    writel(bytes, dma + S2MM_LENGTH);
    return 0;
}

static int m6_transfer_locked(struct model6_dma_dev *m6)
{
    void __iomem *dma = m6_ip(m6, MODEL6_DMA_OFF);
    unsigned long deadline;
    u32 status;
    int ret;

    /* ppe_live.py resets the DMA at the beginning of every frame. */
    ret = m6_reset_locked(m6);
    if (ret)
        return ret;
    writel(DMA_RUNSTOP, dma + MM2S_DMACR);
    writel(DMA_RUNSTOP, dma + S2MM_DMACR);
    ret = m6_start_s2mm(m6, m6->output_dma, MODEL6_DMA_OUTPUT_BYTES);
    if (ret)
        return ret;
    ret = m6_start_mm2s(m6, m6->input_dma, MODEL6_DMA_INPUT_BYTES);
    if (ret)
        return ret;

    deadline = jiffies + usecs_to_jiffies(DMA_TIMEOUT_US);
    for (;;) {
        status = readl(dma + S2MM_DMASR);
        /* The reference accepts DONE even if DMAIntErr is also latched. */
        if (status & DMA_DONE)
            return 0;
        if (status & DMA_ERROR)
            return -EIO;
        if (time_after_eq(jiffies, deadline)) {
            pr_err("MODEL6: timeout done=0 S2MM_DMASR=0x%08x "
                   "S2MM_DMACR=0x%08x S2MM_DA=0x%08x S2MM_LENGTH=%u "
                   "MM2S_DMASR=0x%08x MM2S_DMACR=0x%08x "
                   "MM2S_SA=0x%08x MM2S_LENGTH=%u AFI_FS=0x%08x "
                   "AFIFM_RD=0x%08x AFIFM_WR=0x%08x HLS="
                   "0x%08x/0x%08x/0x%08x/0x%08x/0x%08x/0x%08x\n",
                   status, readl(dma + S2MM_DMACR), readl(dma + S2MM_DA),
                   readl(dma + S2MM_LENGTH), readl(dma + MM2S_DMASR),
                   readl(dma + MM2S_DMACR), readl(dma + MM2S_SA),
                   readl(dma + MM2S_LENGTH), readl(m6->afi_fs),
                   readl(m6->afifm_hp0 + AFIFM_RDCTRL),
                   readl(m6->afifm_hp0 + AFIFM_WRCTRL),
                   readl(m6_ip(m6, MODEL6_CONCAT_OFF) + HLS_AP_CTRL),
                   readl(m6_ip(m6, MODEL6_CONV3X3_OFF) + HLS_AP_CTRL),
                   readl(m6_ip(m6, MODEL6_BN_SILU_OFF) + HLS_AP_CTRL),
                   readl(m6_ip(m6, MODEL6_RESIDUAL_OFF) + HLS_AP_CTRL),
                   readl(m6_ip(m6, MODEL6_ROUTER_OFF) + HLS_AP_CTRL),
                   readl(m6_ip(m6, MODEL6_BN_SILU_128_OFF) + HLS_AP_CTRL));
            return -ETIMEDOUT;
        }
        usleep_range(150, 250);
    }
}

static void m6_work(struct work_struct *work)
{
    struct model6_dma_dev *m6 = container_of(work, struct model6_dma_dev, work);

    mutex_lock(&m6->lock);
    m6->result = m6_transfer_locked(m6);
    if (m6->result)
        m6_reset_locked(m6);
    m6->busy = false;
    complete_all(&m6->complete);
    mutex_unlock(&m6->lock);
}

static int m6_open(struct inode *inode, struct file *file)
{
    struct miscdevice *misc = file->private_data;
    file->private_data = container_of(misc, struct model6_dma_dev, miscdev);
    return 0;
}

static int m6_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct model6_dma_dev *m6 = file->private_data;
    unsigned long requested = vma->vm_end - vma->vm_start;

    if (vma->vm_pgoff == 0 && requested <= MODEL6_DMA_INPUT_BYTES) {
        vma->vm_pgoff = 0;
        return dma_mmap_coherent(m6->dev, vma, m6->input_cpu,
                                 m6->input_dma, MODEL6_DMA_INPUT_BYTES);
    }
    if (vma->vm_pgoff == 1 && requested <= MODEL6_DMA_OUTPUT_BYTES) {
        vma->vm_pgoff = 0;
        return dma_mmap_coherent(m6->dev, vma, m6->output_cpu,
                                 m6->output_dma, MODEL6_DMA_OUTPUT_BYTES);
    }
    return -EINVAL;
}

static long m6_ioctl(struct file *file, unsigned int command, unsigned long argument)
{
    struct model6_dma_dev *m6 = file->private_data;
    struct model6_dma_layout layout = {
        .input_bytes = MODEL6_DMA_INPUT_BYTES,
        .output_bytes = MODEL6_DMA_OUTPUT_BYTES,
        .input_mmap_offset = 0,
        .output_mmap_offset = PAGE_SIZE,
    };
    struct model6_dma_wait wait;
    struct model6_dma_status status;
    long remaining;
    int ret = 0;

    switch (command) {
    case MODEL6_DMA_IOC_ALLOC:
        return copy_to_user((void __user *)argument, &layout, sizeof(layout)) ? -EFAULT : 0;
    case MODEL6_DMA_IOC_PROGRAM:
        mutex_lock(&m6->lock);
        if (m6->busy)
            ret = -EBUSY;
        else {
            m6_program_locked(m6);
            if (!m6->hls_started) {
                m6_start_hls_locked(m6);
                msleep(20);
                m6->hls_started = true;
            }
        }
        mutex_unlock(&m6->lock);
        return ret;
    case MODEL6_DMA_IOC_START:
        mutex_lock(&m6->lock);
        if (m6->busy) {
            ret = -EBUSY;
        } else {
            m6->busy = true;
            m6->result = -EINPROGRESS;
            reinit_completion(&m6->complete);
            schedule_work(&m6->work);
        }
        mutex_unlock(&m6->lock);
        return ret;
    case MODEL6_DMA_IOC_WAIT:
        if (copy_from_user(&wait, (void __user *)argument, sizeof(wait)))
            return -EFAULT;
        remaining = wait_for_completion_interruptible_timeout(
            &m6->complete, msecs_to_jiffies(wait.timeout_ms));
        if (remaining < 0)
            return remaining;
        if (remaining == 0)
            return -ETIMEDOUT;
        mutex_lock(&m6->lock);
        wait.result = m6->result;
        mutex_unlock(&m6->lock);
        return copy_to_user((void __user *)argument, &wait, sizeof(wait)) ? -EFAULT : 0;
    case MODEL6_DMA_IOC_STATUS:
        mutex_lock(&m6->lock);
        status.busy = m6->busy;
        status.result = m6->result;
        mutex_unlock(&m6->lock);
        return copy_to_user((void __user *)argument, &status, sizeof(status)) ? -EFAULT : 0;
    case MODEL6_DMA_IOC_RESET:
        mutex_lock(&m6->lock);
        ret = m6->busy ? -EBUSY : m6_reset_locked(m6);
        mutex_unlock(&m6->lock);
        return ret;
    default:
        return -ENOTTY;
    }
}

static const struct file_operations m6_fops = {
    .owner = THIS_MODULE,
    .open = m6_open,
    .mmap = m6_mmap,
    .unlocked_ioctl = m6_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl = m6_ioctl,
#endif
};

static int m6_probe(struct platform_device *pdev)
{
    struct model6_dma_dev *m6;
    struct resource *resource;
    int ret;

    m6 = devm_kzalloc(&pdev->dev, sizeof(*m6), GFP_KERNEL);
    if (!m6)
        return -ENOMEM;
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
    if (ret)
        return dev_err_probe(&pdev->dev, ret, "32-bit DMA mask unavailable\n");
    resource = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    if (!resource || resource_size(resource) < MODEL6_REG_WINDOW)
        return dev_err_probe(&pdev->dev, -EINVAL,
                             "register resource must cover 0xa0000000-0xa007ffff\n");
    m6->regs = devm_ioremap_resource(&pdev->dev, resource);
    if (IS_ERR(m6->regs))
        return PTR_ERR(m6->regs);
    m6->dev = &pdev->dev;
    m6->afi_fs = devm_ioremap(&pdev->dev, AFI_FS_ADDR, 0x1000);
    m6->afifm_hp0 = devm_ioremap(&pdev->dev, AFIFM_HP0_ADDR, 0x1000);
    if (!m6->afi_fs || !m6->afifm_hp0)
        return dev_err_probe(&pdev->dev, -ENOMEM,
                             "cannot map PS AXI port configuration\n");
    writel((readl(m6->afi_fs) & ~AFI_FS_VALUE_MASK) | AFI_FS_VALUE,
           m6->afi_fs);
    writel((readl(m6->afifm_hp0) & ~0x3) | 0x2,
           m6->afifm_hp0 + AFIFM_RDCTRL);
    writel((readl(m6->afifm_hp0 + AFIFM_WRCTRL) & ~0x3) | 0x2,
           m6->afifm_hp0 + AFIFM_WRCTRL);
    m6->input_cpu = dma_alloc_coherent(m6->dev, MODEL6_DMA_INPUT_BYTES,
                                       &m6->input_dma, GFP_KERNEL);
    if (!m6->input_cpu)
        return -ENOMEM;
    m6->output_cpu = dma_alloc_coherent(m6->dev, MODEL6_DMA_OUTPUT_BYTES,
                                        &m6->output_dma, GFP_KERNEL);
    if (!m6->output_cpu) {
        dma_free_coherent(m6->dev, MODEL6_DMA_INPUT_BYTES,
                          m6->input_cpu, m6->input_dma);
        return -ENOMEM;
    }
    mutex_init(&m6->lock);
    init_completion(&m6->complete);
    INIT_WORK(&m6->work, m6_work);
    m6->result = 0;
    m6->miscdev.minor = MISC_DYNAMIC_MINOR;
    m6->miscdev.name = "model6_dma";
    m6->miscdev.fops = &m6_fops;
    m6->miscdev.parent = &pdev->dev;
    ret = misc_register(&m6->miscdev);
    if (ret) {
        dma_free_coherent(m6->dev, MODEL6_DMA_OUTPUT_BYTES,
                          m6->output_cpu, m6->output_dma);
        dma_free_coherent(m6->dev, MODEL6_DMA_INPUT_BYTES,
                          m6->input_cpu, m6->input_dma);
        return ret;
    }
    platform_set_drvdata(pdev, m6);
    return 0;
}

static int m6_remove(struct platform_device *pdev)
{
    struct model6_dma_dev *m6 = platform_get_drvdata(pdev);

    cancel_work_sync(&m6->work);
    misc_deregister(&m6->miscdev);
    dma_free_coherent(m6->dev, MODEL6_DMA_OUTPUT_BYTES,
                      m6->output_cpu, m6->output_dma);
    dma_free_coherent(m6->dev, MODEL6_DMA_INPUT_BYTES,
                      m6->input_cpu, m6->input_dma);
    return 0;
}

static const struct of_device_id m6_of_match[] = {
    { .compatible = "ppe,kv260-model6-dma-1.0" },
    { }
};
MODULE_DEVICE_TABLE(of, m6_of_match);

static struct platform_driver m6_driver = {
    .probe = m6_probe,
    .remove = m6_remove,
    .driver = {
        .name = "model6_dma",
        .of_match_table = m6_of_match,
    },
};
module_platform_driver(m6_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("KV260 model.6 direct AXI DMA proxy");
MODULE_INFO(model6_source, "run_model6-fullframe-v4");
