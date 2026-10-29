"""KVJ 的图标：用户那张小熊 + TNT 的照片，取中心方块，周边径向淡化沉进底色。

    python3 make.py <照片> <输出目录>      # 需要 Pillow 和 numpy

照片不入库。输出目录里得到：
  icon-1024.png    母版
  icon-256.png     README 顶上那张（docs/readme-assets/icon.png）
  KVJ.iconset/     macOS：按 Apple 模板，圆角方块占画布 824/1024，四周留透明边，
                   和 Dock 里别的图标一样大；iconutil -c icns 打成 KVJ.icns
  KVJ.ico          Windows：16–256 每档一张，铺满画布

每档单独从照片渲染，不是把 1024 缩下去：圆角和淡化按那一档的像素算，小图不糊。
"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw

S = 4                         # 超采样倍数
BG = (11, 13, 17)             # Theme.qml 深色底 #0b0d11
RADIUS = 0.225                # macOS squircle 的圆角近似

# 用户定下的参考图的取景和淡化（2026-10-29）
SIDE, CX, CY = 0.74, 0.47, 0.51
FADE_START, FADE_END, POWER = 0.42, 0.98, 1.7

def tile(photo, n):
    """n×n 的方块：取景、淡化、圆角，不含透明边。"""
    W, H = photo.size
    side = int(W * SIDE)
    x0 = max(0, min(W - side, int(W * CX - side / 2)))
    y0 = max(0, min(H - side, int(H * CY - side / 2)))
    crop = photo.crop((x0, y0, x0 + side, y0 + side)).resize((n, n), Image.LANCZOS)
    arr = np.asarray(crop).astype(np.float32)
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    half = n / 2
    # d=1 落在四边中点：边上真正黑掉，角上更黑
    d = np.sqrt((xx - half) ** 2 + (yy - half) ** 2) / half
    t = np.clip((d - FADE_START) / (FADE_END - FADE_START), 0, 1)
    gain = ((1 - t) ** POWER)[..., None]
    out = arr * gain + np.array(BG, np.float32) * (1 - gain)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * RADIUS), fill=255)
    img.paste(Image.fromarray(out.astype(np.uint8)), (0, 0), mask)
    return img

def render(photo, size, content=1.0):
    """size×size 的图标，方块占 content 那么宽，居中。"""
    n = size * S
    inner = round(n * content)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    off = (n - inner) // 2
    img.alpha_composite(tile(photo, inner), (off, off))
    return img.resize((size, size), Image.LANCZOS)

def main(src, out):
    photo = Image.open(src).convert("RGB")
    os.makedirs(out, exist_ok=True)
    render(photo, 1024).save(os.path.join(out, "icon-1024.png"))
    render(photo, 256).save(os.path.join(out, "icon-256.png"))

    iconset = os.path.join(out, "KVJ.iconset")
    os.makedirs(iconset, exist_ok=True)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            render(photo, px, content=824 / 1024).save(os.path.join(iconset, name))

    sizes = [256, 128, 64, 48, 32, 24, 16]
    frames = [render(photo, s) for s in sizes]
    frames[0].save(os.path.join(out, "KVJ.ico"), format="ICO",
                   sizes=[(s, s) for s in sizes], append_images=frames[1:])

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
