import time, torch
import torch.nn.functional as F
torch.set_num_threads(4)

def timeit(fn, n):
    for _ in range(3): fn()
    t = time.monotonic()
    for _ in range(n): fn()
    return (time.monotonic() - t) / n

n = 512
a = torch.randn(n, n); b = torch.randn(n, n)
dt = timeit(lambda: a @ b, 20)
print("행렬곱 512x512      %6.2f GFLOP/s" % (2 * n**3 / dt / 1e9))

x = torch.randn(1, 64, 160, 160); w = torch.randn(64, 64, 3, 3)
dt = timeit(lambda: F.conv2d(x, w, padding=1), 10)
print("3x3 conv 64ch 160^2 %6.2f GFLOP/s" % (2*64*64*9*160*160 / dt / 1e9))

x = torch.randn(1, 128, 40, 40); w = torch.randn(128, 128, 1, 1)
dt = timeit(lambda: F.conv2d(x, w), 20)
print("1x1 conv 128ch 40^2 %6.2f GFLOP/s" % (2*128*128*1600 / dt / 1e9))
