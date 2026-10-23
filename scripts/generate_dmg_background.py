#!/usr/bin/env python3
"""Generates the background of the Nook installer window (the .dmg the release workflow publishes).

Draws Nook's own layout in NookTheme's colors: the notch opening into the Nook panel (its tabs, an agent that is done,
a chat waiting on you), and under it the drag-to-Applications row the Finder icons sit on. Writes
apps/macos/Config/DMG/background.png (1x) and background@2x.png (Retina); the release workflow combines them into one
TIFF and lays the window out with dmgbuild (see apps/macos/Config/DMG/settings.py, which must keep the same
window size and icon positions as WIDTH, HEIGHT, APP_ICON and APPS_ICON below).

Requires Pillow and the Inter font (the closest free cut to SF Pro): python3 scripts/generate_dmg_background.py
[--font-dir DIR]
"""

import argparse
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Window size in points, and the centers of the two Finder icons (keep in sync with Config/DMG/settings.py).
WIDTH, HEIGHT = 660, 460
APP_ICON = (170, 318)
APPS_ICON = (490, 318)

# NookTheme colors.
NOTCH = (0, 0, 0)
CANVAS = (0x0A, 0x0A, 0x0A)
SURFACE = (0x12, 0x12, 0x12)
GRAPHITE = (0x17, 0x17, 0x17)
SMOKE = (0x1F, 0x1F, 0x1F)
SEPARATOR = (0x2B, 0x2B, 0x2B)
PAPER = (0xF5, 0xF5, 0xF5)
TEXT_STRONG = (0xD6, 0xD6, 0xD6)
TEXT_SECONDARY = (0x99, 0x99, 0x99)
TEXT_TERTIARY = (0x6E, 0x6E, 0x6E)
IRIS = (0xF4, 0xF3, 0xF7)
EYE_INK = (0x05, 0x05, 0x07)
MINT = (0x5E, 0xD6, 0xA6)
AMBER = (0xF2, 0xB8, 0x66)

# Drawn at SUPERSAMPLE times the output size, then scaled down, for smooth edges.
SUPERSAMPLE = 3

FONT_DIRS = ["/usr/share/fonts/opentype/inter", "/Library/Fonts", os.path.expanduser("~/Library/Fonts")]


class Canvas:
    def __init__(self, scale, font_dir):
        self.s = scale * SUPERSAMPLE
        self.image = Image.new("RGB", (WIDTH * self.s, HEIGHT * self.s), CANVAS)
        self.draw = ImageDraw.Draw(self.image)
        self.font_dir = font_dir
        self.fonts = {}

    def px(self, value):
        return round(value * self.s)

    def box(self, x, y, w, h):
        return [self.px(x), self.px(y), self.px(x + w), self.px(y + h)]

    def font(self, size, weight="Regular"):
        key = (size, weight)
        if key not in self.fonts:
            self.fonts[key] = ImageFont.truetype(str(self.font_dir / f"Inter-{weight}.otf"), self.px(size))
        return self.fonts[key]

    def rect(self, x, y, w, h, radius, fill, corners=None):
        self.draw.rounded_rectangle(self.box(x, y, w, h), radius=self.px(radius), fill=fill, corners=corners)

    def circle(self, cx, cy, r, fill):
        self.draw.ellipse(self.box(cx - r, cy - r, 2 * r, 2 * r), fill=fill)

    def text(self, x, y, value, size, fill, weight="Regular", anchor="la"):
        self.draw.text((self.px(x), self.px(y)), value, font=self.font(size, weight), fill=fill, anchor=anchor)

    def text_width(self, value, size, weight="Regular"):
        return self.draw.textlength(value, font=self.font(size, weight)) / self.s

    def glow(self, cx, cy, rx, ry, color, alpha, blur):
        """A soft light behind the panel: an ellipse blurred into the canvas."""
        layer = Image.new("L", self.image.size, 0)
        ImageDraw.Draw(layer).ellipse(self.box(cx - rx, cy - ry, 2 * rx, 2 * ry), fill=alpha)
        layer = layer.filter(ImageFilter.GaussianBlur(self.px(blur)))
        self.image.paste(Image.new("RGB", self.image.size, color), mask=layer)

    def shadow(self, x, y, w, h, radius, alpha, blur, offset=0):
        layer = Image.new("L", self.image.size, 0)
        ImageDraw.Draw(layer).rounded_rectangle(self.box(x, y + offset, w, h), radius=self.px(radius), fill=alpha)
        layer = layer.filter(ImageFilter.GaussianBlur(self.px(blur)))
        self.image.paste(Image.new("RGB", self.image.size, NOTCH), mask=layer)

    def output(self, scale):
        return self.image.resize((WIDTH * scale, HEIGHT * scale), Image.LANCZOS)


def draw_orb(c, cx, cy, r):
    """Nook's character: a soft white orb with two upright eyes, as on the app icon."""
    c.circle(cx, cy, r, IRIS)
    eye_w, eye_h = r * 0.22, r * 0.6
    for dx in (-0.29, 0.29):
        ex = cx + dx * r - eye_w / 2
        c.rect(ex, cy - eye_h * 0.62, eye_w, eye_h, eye_w / 2, EYE_INK)


def draw_card(c, x, y, w, title, detail, status, color, trailing):
    """One row of the panel: a status dot, a title over its detail, and a status word on the right."""
    c.rect(x, y, w, 46, 10, GRAPHITE)
    c.circle(x + 18, y + 23, 4, color)
    c.text(x + 32, y + 9, title, 12.5, PAPER, "SemiBold")
    c.text(x + 32, y + 26, detail, 10.5, TEXT_SECONDARY)
    tw = c.text_width(status, 10, "Medium") + 16
    c.rect(x + w - tw - 12, y + 14, tw, 18, 9, tuple(int(v * 0.16 + 0x17 * 0.84) for v in color))
    c.text(x + w - tw / 2 - 12, y + 23, status, 10, color, "Medium", anchor="mm")
    if trailing:
        c.text(x + w - tw - 22, y + 23, trailing, 10, TEXT_TERTIARY, anchor="rm")


def draw_panel(c):
    # The menu bar, faint, so the notch reads as the top of the screen.
    c.rect(0, 0, WIDTH, 24, 0, (0x0E, 0x0E, 0x0E))
    c.rect(0, 24, WIDTH, 1, 0, (0x16, 0x16, 0x16))
    for i, word in enumerate(["Finder", "File"]):
        c.text(22 + i * 48 + (6 if i else 0), 12, word, 10.5, TEXT_TERTIARY if i else TEXT_SECONDARY,
               "SemiBold" if i == 0 else "Regular", anchor="lm")
    c.text(WIDTH - 22, 12, "Thu 09:41", 10.5, TEXT_SECONDARY, anchor="rm")

    # The notch, opened into the Nook panel.
    pw, ph = 400, 198
    px = (WIDTH - pw) / 2
    c.glow(WIDTH / 2, 120, 250, 110, (0x2A, 0x2A, 0x30), 120, 40)
    c.shadow(px, 0, pw, ph, 22, 200, 14, offset=8)
    c.rect(px, 0, pw, ph, 22, NOTCH, corners=(False, False, True, True))

    # Header: the orb, the tabs (Nook selected), and the time.
    draw_orb(c, px + 26, 40, 11)
    tx = px + 48
    for i, tab in enumerate(["Nook", "Chat", "Agents", "Music", "Shelf"]):
        tw = c.text_width(tab, 11, "Medium") + 18
        if i == 0:
            c.rect(tx, 30, tw, 21, 10.5, SMOKE)
        c.text(tx + tw / 2, 40.5, tab, 11, PAPER if i == 0 else TEXT_SECONDARY, "Medium", anchor="mm")
        tx += tw + 2
    c.text(px + pw - 20, 40.5, "3 new", 10.5, TEXT_TERTIARY, anchor="rm")

    # Two rows of what Nook keeps an eye on.
    cx, cw = px + 14, pw - 28
    draw_card(c, cx, 64, cw, "Claude Code · nook", "Refactor finished, tests pass", "Done", MINT, "2m")
    draw_card(c, cx, 116, cw, "Sam", "Are we still on for tonight?", "Waiting", AMBER, "now")

    # The composer at the bottom of the panel.
    c.rect(cx, 168, cw, 20, 10, SURFACE)
    c.text(cx + 12, 178, "Ask Nook anything…", 10.5, TEXT_TERTIARY, anchor="lm")


def draw_install_row(c):
    # A tray the two icons rest on, and an arrow from Nook to Applications.
    c.rect(60, 248, WIDTH - 120, 156, 18, (0x10, 0x10, 0x10))
    y = APP_ICON[1]
    x0, x1 = APP_ICON[0] + 78, APPS_ICON[0] - 78
    for i in range(int((x1 - x0 - 16) / 10) + 1):
        c.circle(x0 + i * 10, y, 1.6, (0x4A, 0x4A, 0x4A))
    c.draw.polygon([(c.px(x1 - 12), c.px(y - 7)), (c.px(x1), c.px(y)), (c.px(x1 - 12), c.px(y + 7))], fill=TEXT_SECONDARY)

    # The headline under the tray.
    line = "Drag Nook to Applications"
    c.text(WIDTH / 2, 426, line, 13, TEXT_STRONG, "SemiBold", anchor="mm")
    c.text(WIDTH / 2, 444, "Then open it: Nook lives in your notch.", 10.5, TEXT_TERTIARY, anchor="mm")


def find_font_dir(override):
    for directory in [override] if override else FONT_DIRS:
        if directory and (Path(directory) / "Inter-Regular.otf").exists():
            return Path(directory)
    raise SystemExit("Inter not found; pass --font-dir with Inter-Regular.otf in it")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font-dir")
    parser.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "apps/macos/Config/DMG"))
    args = parser.parse_args()
    font_dir = find_font_dir(args.font_dir)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for scale, name in [(1, "background.png"), (2, "background@2x.png")]:
        c = Canvas(scale, font_dir)
        draw_panel(c)
        draw_install_row(c)
        image = c.output(scale)
        image.info["dpi"] = (72 * scale, 72 * scale)
        image.save(out / name, dpi=(72 * scale, 72 * scale), optimize=True)
        print(f"Wrote {out / name}")


if __name__ == "__main__":
    main()
