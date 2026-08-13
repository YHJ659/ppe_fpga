#!/usr/bin/env python3
"""Create a presentation-ready diagram for the model.6 C2f accelerator."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path("/home/sogang/ppe_fpga_ho/artifacts/ppt_assets/model6_c2f_design.png")
W, H = 1800, 920

NAVY = (14, 31, 53)
BLUE = (35, 108, 180)
CYAN = (33, 170, 190)
GREEN = (50, 156, 105)
ORANGE = (235, 139, 54)
RED = (205, 73, 73)
WHITE = (255, 255, 255)
LIGHT = (242, 246, 250)
MID = (190, 204, 219)
DARK = (39, 48, 59)
GRAY = (102, 113, 124)

FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
f_title = ImageFont.truetype(FONT, 48)
f_head = ImageFont.truetype(FONT, 30)
f_body = ImageFont.truetype(FONT, 24)
f_small = ImageFont.truetype(FONT, 20)

img = Image.new("RGB", (W, H), WHITE)
d = ImageDraw.Draw(img)


def centered_text(box, text, font, fill=DARK):
    x1, y1, x2, y2 = box
    bb = d.multiline_textbbox((0, 0), text, font=font, spacing=4, align="center")
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    d.multiline_text(((x1+x2-tw)/2, (y1+y2-th)/2), text, font=font,
                     fill=fill, spacing=4, align="center")


def block(x, y, w, h, title, detail, color):
    d.rounded_rectangle((x, y, x+w, y+h), 20, fill=LIGHT, outline=color, width=5)
    d.rounded_rectangle((x, y, x+w, y+48), 18, fill=color, outline=color)
    centered_text((x, y, x+w, y+48), title, f_small, WHITE)
    centered_text((x+8, y+50, x+w-8, y+h-5), detail, f_body, DARK)


def arrow(x1, y1, x2, y2, color=MID, width=7):
    d.line((x1, y1, x2, y2), fill=color, width=width)
    if abs(x2-x1) >= abs(y2-y1):
        s = 15 if x2 >= x1 else -15
        d.polygon([(x2, y2), (x2-s, y2-11), (x2-s, y2+11)], fill=color)
    else:
        s = 15 if y2 >= y1 else -15
        d.polygon([(x2, y2), (x2-11, y2-s), (x2+11, y2-s)], fill=color)


d.text((55, 34), "YOLOv8n model.6 C2f — FPGA 통합 설계", font=f_title, fill=NAVY)
d.text((57, 100), "본인 담당 범위: HLS IP 인터페이스 확인 · Vivado Block Design 통합 · Timing/DRC/Bitstream 검증",
       font=f_small, fill=GRAY)

# Main path
block(45, 190, 190, 120, "DMA INPUT", "INT8 HWC\n40×40×128", BLUE)
block(290, 190, 190, 120, "cv1", "Conv 1×1\n128 → 128", CYAN)
block(535, 190, 190, 120, "BN + SiLU", "128 ch\nINT32 → INT8", GREEN)
block(780, 190, 190, 120, "SPLIT", "64 ch + 64 ch\ny0       y1", ORANGE)
for a, b in [(235,290),(480,535),(725,780)]: arrow(a,250,b,250)

# Bottleneck lanes
block(1040, 150, 250, 175, "BOTTLENECK 0", "Conv3×3 → BN/SiLU\nConv3×3 → BN/SiLU\nResidual Add → y2", RED)
block(1370, 150, 250, 175, "BOTTLENECK 1", "Conv3×3 → BN/SiLU\nConv3×3 → BN/SiLU\nResidual Add → y3", RED)
arrow(970,250,1040,250)
arrow(1290,237,1370,237)

# Four concat branches
d.text((770, 390), "C2f feature reuse", font=f_head, fill=NAVY)
ys = [475, 555, 635, 715]
labels = [("y0", "64×40×40", BLUE), ("y1", "64×40×40", CYAN),
          ("y2", "64×40×40", GREEN), ("y3", "64×40×40", ORANGE)]
for y, (name, shape, color) in zip(ys, labels):
    d.rounded_rectangle((650, y, 900, y+55), 14, fill=LIGHT, outline=color, width=4)
    d.text((680, y+10), name, font=f_body, fill=color)
    d.text((750, y+10), shape, font=f_small, fill=DARK)
    arrow(900, y+27, 1080, y+27, color)

block(1080, 500, 230, 210, "FPGA OUTPUT", "Concat y0+y1+y2+y3\n64×4 = 256 ch\nHWC 40×40×256", ORANGE)
block(1380, 530, 190, 150, "CPU cv2", "Float Conv 1×1\n256 → 128", GRAY)
block(1610, 530, 155, 150, "C2f OUTPUT", "Float\n128×40×40", BLUE)
arrow(1310,605,1380,605)
arrow(1570,605,1610,605)

# The four labeled rows summarize the values retained for C2f concatenation.

# Final main branch boundary: cv1~concat is PL, cv2 and later layers are CPU.
for yy in range(420, 790, 24):
    d.line((1345, yy, 1345, min(yy+12, 790)), fill=RED, width=4)
d.text((1045, 785), "PL / FPGA: cv1 ~ Concat", font=f_small, fill=GREEN)
d.text((1380, 785), "PS / CPU: cv2 ~ Detect", font=f_small, fill=RED)

# Footer legend
d.rounded_rectangle((45, 825, 1715, 885), 16, fill=NAVY, outline=NAVY)
centered_text((45,825,1715,885),
              "실제 main 최종 경계  |  DMA/HLS 배열: HWC  |  FPGA: cv1~Concat(INT8)  |  CPU: cv2 이후(float)  |  PL: 100 MHz",
              f_small, WHITE)

OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print(OUT)
