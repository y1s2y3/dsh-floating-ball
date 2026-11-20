import os
from PIL import Image, ImageDraw, ImageFont

ROOT = r"C:\Users\13065\Desktop\plugin\dsh-floating-ball\assets"
W, H = 900, 383
SS = 2  # supersample for the cover

def font(path, size):
    return ImageFont.truetype(path, size)

MSYH = r"C:\Windows\Fonts\msyh.ttc"
MSYHBD = r"C:\Windows\Fonts\msyhbd.ttc"
SEGOEB = r"C:\Windows\Fonts\segoeuib.ttf"
SEGOE = r"C:\Windows\Fonts\segoeui.ttf"

icon = Image.open(os.path.join(ROOT, "icon-1024.png")).convert("RGBA")

# ---------------------------------------------------------------- size preview
preview = Image.new("RGBA", (900, 360), (255, 255, 255, 255))
draw = ImageDraw.Draw(preview)
label_font = font(MSYH, 15)
rows = [
    ("浅色背景", (247, 248, 250, 255), (21, 21, 23, 255)),
    ("深色背景", (21, 21, 23, 255), (233, 238, 247, 255)),
]
sizes = [128, 64, 48, 32, 16]
for row_index, (title, bg, fg) in enumerate(rows):
    top = 10 + row_index * 175
    draw.rounded_rectangle([10, top, 890, top + 160], radius=12, fill=bg)
    draw.text((28, top + 12), title, font=label_font, fill=fg)
    x = 60
    for size in sizes:
        img = Image.open(os.path.join(ROOT, f"icon-{size}.png")).convert("RGBA")
        y = top + 40
        preview.alpha_composite(img, (x, y))
        draw.text((x, top + 40 + 132), f"{size}px", font=label_font, fill=fg)
        x += size + 78
preview.save(os.path.join(ROOT, "preview-sizes.png"))

# ---------------------------------------------------------------- wechat cover
cover = Image.new("RGBA", (W * SS, H * SS), (247, 248, 250, 255))
cd = ImageDraw.Draw(cover)

# soft vertical gradient
for y in range(H * SS):
    t = y / (H * SS)
    r = int(247 - 9 * t)
    g = int(248 - 9 * t)
    b = int(250 - 7 * t)
    cd.line([(0, y), (W * SS, y)], fill=(r, g, b, 255))

# left: the ball, with a soft ground shadow
ball_size = 560
ball = icon.resize((ball_size, ball_size), Image.LANCZOS)
shadow = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.ellipse([150, H * SS - 150, 150 + ball_size + 40, H * SS - 90], fill=(20, 30, 60, 26))
shadow = shadow.filter(__import__("PIL.ImageFilter", fromlist=["GaussianBlur"]).GaussianBlur(18))
cover.alpha_composite(shadow)
ball_x, ball_y = 60, (H * SS - ball_size) // 2 - 10
cover.alpha_composite(ball, (ball_x, ball_y))

# right: 非官方 pill + title + subtitle + capability line
right_x = 700
pill_text = "非官方 · 社区插件"
pill_font = font(MSYH, 24)
pill_bbox = cd.textbbox((0, 0), pill_text, font=pill_font)
pill_w = pill_bbox[2] - pill_bbox[0] + 44
pill_h = 48
cd.rounded_rectangle([right_x, 74, right_x + pill_w, 74 + pill_h], radius=24,
                     fill=(232, 238, 255, 255), outline=(176, 194, 245, 255), width=2)
cd.text((right_x + 22, 84), pill_text, font=pill_font, fill=(59, 96, 190, 255))

title_font = font(SEGOEB, 66)
cd.text((right_x - 2, 142), "dsh-floating-ball", font=title_font, fill=(21, 21, 23, 255))

sub_font = font(MSYHBD, 31)
cd.text((right_x, 232), "DSH 悬浮球：任务跑完没有，一眼就知道", font=sub_font, fill=(60, 60, 61, 255))

cap_font = font(MSYH, 22)
cd.text((right_x, 292), "Windows 置顶 · 会话状态 · 面板内直接回话", font=cap_font, fill=(129, 133, 140, 255))

cover = cover.resize((W, H), Image.LANCZOS)
cover.convert("RGB").save(os.path.join(ROOT, "cover-wechat-900x383.png"))

print("assets written")
for name in ["preview-sizes.png", "cover-wechat-900x383.png"]:
    p = os.path.join(ROOT, name)
    print(name, os.path.getsize(p))
