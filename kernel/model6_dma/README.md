# model6_dma kernel module

Build this module against the exact KV260 kernel headers and configuration:

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/kernel/model6_dma modules
```

Add the contents of `model6_dma.dtsi` beneath the PL AXI bus in the KV260
Linux device tree, rebuild/install that DTB, then boot with the existing
model.6 bitstream already programmed.  The node reserves one verified AXI-Lite
window, `0xa0000000` through `0xa007ffff`; it covers the exported concat,
conv3x3, BN, residual, router, AXI DMA, and BN128 register ranges.

On the board:

```bash
sudo insmod model6_dma.ko
ls -l /dev/model6_dma
make -C hw
python3 webcam_infer.py
```

The module allocates the two buffers with `dma_alloc_coherent()`.  Userspace
must use only the mmap regions returned by its UAPI; it must not supply DMA
addresses or perform cache maintenance.
