#!/usr/bin/env python3
"""Generate the SparkWatch app icon (all macOS sizes → .icns).

Usage: python3 Scripts/make-icon.py <output-dir>

Design: two stacked node cards (the app's own visual language) with a status
lamp on each and a decode-rate trace underneath. Apple's Big Sur grid: the
artwork is 824pt inside a 1024 canvas, corner radius 185.5 — the same rule used
for macfan's icon, so the two apps sit consistently in the Dock.
"""
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
ART = 824
RADIUS = 185.5

NAVY_TOP = (38, 62, 110)
NAVY_BOTTOM = (10, 16, 30)
GREEN = (48, 209, 88)
AMBER = (255, 149, 0)
CARD = (255, 255, 255, 30)
CARD_EDGE = (255, 255, 255, 70)


def rounded(size, radius, **kwargs):
    return Image.new("RGBA", size, (0, 0, 0, 0)), ImageDraw.Draw(Image.new("RGBA", size))


def gradient_square(size):
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        colour = tuple(
            int(NAVY_TOP[i] + (NAVY_BOTTOM[i] - NAVY_TOP[i]) * t) for i in range(3)
        )
        draw.line([(0, y), (size, y)], fill=colour + (255,))
    return img


def squircle_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def card(draw, x, y, w, h, lamp):
    draw.rounded_rectangle([x, y, x + w, y + h], radius=h * 0.28, fill=CARD, outline=CARD_EDGE, width=3)
    # status lamp
    r = h * 0.16
    cx, cy = x + h * 0.42, y + h / 2
    glow = Image.new("RGBA", (int(r * 6), int(r * 6)), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [r * 2, r * 2, r * 4, r * 4], fill=lamp + (110,)
    )
    glow = glow.filter(ImageFilter.GaussianBlur(r * 0.9))
    draw._image.alpha_composite(glow, (int(cx - r * 3), int(cy - r * 3)))
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=lamp + (255,))
    # three value bars
    bar_h = h * 0.14
    for i, frac in enumerate((0.72, 0.5, 0.34)):
        bx = x + h * 0.95 + i * (w * 0.19)
        bw = w * 0.15
        by = cy - bar_h / 2
        draw.rounded_rectangle(
            [bx, by, bx + bw * frac, by + bar_h], radius=bar_h / 2, fill=(255, 255, 255, 190)
        )


def trace(draw, x, y, w, h, points):
    step = w / (len(points) - 1)
    path = [(x + i * step, y + h - p * h) for i, p in enumerate(points)]
    glow = Image.new("RGBA", (int(w + h * 4), int(h * 4)), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.line(
        [(px - x + h * 2, py - y + h * 1.5) for px, py in path],
        fill=GREEN + (150,), width=int(h * 0.5), joint="curve",
    )
    glow = glow.filter(ImageFilter.GaussianBlur(h * 0.22))
    draw._image.alpha_composite(glow, (int(x - h * 2), int(y - h * 1.5)))
    draw.line(path, fill=GREEN + (255,), width=int(h * 0.26), joint="curve")
    for i, p in enumerate(points):
        if i == len(points) - 1:
            r = h * 0.16
            draw.ellipse(
                [path[i][0] - r, path[i][1] - r, path[i][0] + r, path[i][1] + r],
                fill=GREEN + (255,),
            )


def render(size=CANVAS):
    art = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    scale = size / CANVAS

    # background
    bg = gradient_square(size)
    mask = squircle_mask(size, RADIUS * scale)
    art.paste(bg, (0, 0), mask)

    # inner top highlight
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(highlight).ellipse(
        [-size * 0.35, -size * 0.75, size * 1.35, size * 0.42],
        fill=(255, 255, 255, 22),
    )
    art.alpha_composite(Image.composite(highlight, Image.new("RGBA", (size, size), (0, 0, 0, 0)), mask))

    canvas = ImageDraw.Draw(art)
    canvas._image = art

    inset = (CANVAS - ART) / 2
    cw, ch = ART * 0.90, ART * 0.30
    cx = inset + (ART - cw) / 2

    # A second card peeking out behind the first: the "cluster" idea without
    # duplicating the same shape twice at the same weight.
    back = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    back_draw = ImageDraw.Draw(back)
    back_draw.rounded_rectangle(
        [cx * scale + 26 * scale, (inset + ART * 0.10) * scale + 26 * scale,
         (cx + cw) * scale + 26 * scale, (inset + ART * 0.10 + ch) * scale + 26 * scale],
        radius=ch * 0.30 * scale, fill=(255, 255, 255, 16), outline=(255, 255, 255, 40),
        width=int(3 * scale),
    )
    art.alpha_composite(back)

    # Hero card, vertically centred in the artwork.
    hero_y = inset + (ART - ch) / 2 - ART * 0.03
    card(canvas, cx * scale, hero_y * scale, cw * scale, ch * scale, GREEN)

    # The pulse is the hero: thicker, glowing, spanning the card.
    trace(
        canvas,
        (cx + ART * 0.045) * scale,
        (hero_y + ch * 0.60) * scale,
        (cw - ART * 0.09) * scale,
        ART * 0.14 * scale,
        [0.10, 0.34, 0.18, 0.66, 0.44, 1.0, 0.72, 0.96],
    )
    return art


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "dist")
    out.mkdir(parents=True, exist_ok=True)
    iconset = out / "SparkWatch.iconset"
    if iconset.exists():
        subprocess.run(["rm", "-rf", str(iconset)], check=True)
    iconset.mkdir(parents=True)

    master = render()
    for name, px in (
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ):
        master.resize((px, px), Image.LANCZOS).save(iconset / f"{name}.png")

    icns = out / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    subprocess.run(["rm", "-rf", str(iconset)], check=True)
    print(f"icon written: {icns}")


if __name__ == "__main__":
    main()
