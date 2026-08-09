import time, torch, json
from ultralytics import YOLO
torch.set_num_threads(4)
y = YOLO("models/best.pt"); y.model.eval(); net = y.model
x = torch.randn(1, 3, 640, 640)
acc = {}
with torch.no_grad():
    for _ in range(4):
        yy = []; xx = x
        for m in net.model:
            if m.f != -1:
                xx = yy[m.f] if isinstance(m.f, int) else [xx if j == -1 else yy[j] for j in m.f]
            t = time.monotonic(); out = m(xx); dt = time.monotonic() - t
            acc.setdefault(m.i, []).append(dt)
            xx = out
            yy.append(xx if m.i in net.save else None)
tot = sum(min(v) for v in acc.values())
print("레이어별 시간 (4회 중 최소, 초)   합계 %.3f s" % tot)
rows = sorted(acc.items(), key=lambda kv: -min(kv[1]))
for i, v in rows[:12]:
    nm = type(net.model[i]).__name__
    print("  %2d  %-10s %.4f  %5.1f%%" % (i, nm, min(v), min(v)/tot*100))
print("  ---")
print("  model.6 (지금 FPGA 로 뺀 것)  %.4f  %.1f%%" % (min(acc[6]), min(acc[6])/tot*100))
g = [0,1,2,3,4,5]; h = [6]; k = [i for i in acc if i > 6]
for nm, idx in (("0~5", g), ("6", h), ("7~22", k)):
    s = sum(min(acc[i]) for i in idx)
    print("  %-6s %.4f s  %5.1f%%" % (nm, s, s/tot*100))
