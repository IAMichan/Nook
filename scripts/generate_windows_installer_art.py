#!/usr/bin/env python3
"""Generates the images of Nook's Windows installers (the NSIS setup .exe and the .msi), in the look of the macOS one.

The welcome and finish pages get a dark side panel in NookTheme's colors: Nook's orb in a soft glow with his name
under it, as on the .dmg window and the release banner (scripts/generate_dmg_background.py, whose drawing this
reuses). The pages in between get a light header with the app icon, so it sits calmly in Windows' own window.

Writes into apps/tauri/src-tauri/windows/ (tauri.conf.json points at these files):
  nsis-sidebar.bmp  164x314  welcome and finish pages of the setup .exe
  nsis-header.bmp   150x57   top left of the other pages of the setup .exe and the uninstaller
  wix-dialog.bmp    493x312  welcome and finish pages of the .msi (the text is drawn on its right part)
  wix-banner.bmp    493x58   top of the other pages of the .msi (the text is drawn on its left part)

The header images use apps/tauri/src-tauri/icons/icon.png, drawn by scripts/generate_app_icon.swift; run that first
when the icon changes.

Requires Pillow and the Inter font: python3 scripts/generate_windows_installer_art.py [--font-dir DIR]
"""

import argparse
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_dmg_background import PAPER, TEXT_TERTIARY, Canvas, draw_orb, find_font_dir  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps/tauri/src-tauri/windows"
ICON = ROOT / "apps/tauri/src-tauri/icons/icon.png"

# The color Windows fills an installer page with (COLOR_WINDOW), so the header images run into it without an edge.
WINDOW = (255, 255, 255)
# The thin line between the dark side panel and the white page of the .msi welcome dialog.
EDGE = (0x26, 0x26, 0x26)

SIDEBAR = (164, 314)
WIX_DIALOG = (493, 312)


def draw_side_panel(c, width, height):
    """Nook in the dark: a faint light behind his orb, his name under it, and a quiet line at the bottom."""
    cx, cy = width / 2, height * 0.40
    c.glow(cx, cy, 70, 70, (0x2E, 0x2E, 0x34), 150, 26)
    c.glow(cx, cy, 34, 34, (0x5A, 0x5A, 0x62), 70, 14)
    draw_orb(c, cx, cy, 30)
    c.text(cx, cy + 58, "Nook", 22, PAPER, "SemiBold", anchor="mm")
    c.text(cx, height - 22, "for Windows", 10, TEXT_TERTIARY, anchor="mm")


def sidebar(font_dir):
    c = Canvas(1, font_dir, size=SIDEBAR)
    draw_side_panel(c, *SIDEBAR)
    return c.output(1)


def wix_dialog(font_dir):
    """The .msi welcome page: the same side panel on the left 164 pixels, white where Windows draws the text."""
    panel = sidebar(font_dir)
    image = Image.new("RGB", WIX_DIALOG, WINDOW)
    image.paste(panel.crop((0, 0, SIDEBAR[0], WIX_DIALOG[1])), (0, 0))
    image.paste(EDGE, [SIDEBAR[0], 0, SIDEBAR[0] + 1, WIX_DIALOG[1]])
    return image


def icon(size):
    return Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)


def header(size, icon_size, x):
    """A white strip with the app icon at `x`, vertically centered."""
    image = Image.new("RGB", size, WINDOW)
    mark = icon(icon_size)
    image.paste(mark, (x, (size[1] - icon_size) // 2), mark)
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font-dir")
    parser.add_argument("--out", default=str(OUT))
    args = parser.parse_args()
    font_dir = find_font_dir(args.font_dir)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    images = {
        "nsis-sidebar.bmp": sidebar(font_dir),
        # NSIS puts the header image on the left of the page title; the icon sits in its middle.
        "nsis-header.bmp": header((150, 57), 40, (150 - 40) // 2),
        "wix-dialog.bmp": wix_dialog(font_dir),
        # The .msi draws the page title over the left of the banner, so the icon goes on the right.
        "wix-banner.bmp": header((493, 58), 40, 493 - 40 - 12),
    }
    for name, image in images.items():
        # 24-bit BMP: the format NSIS and WiX both read.
        image.convert("RGB").save(out / name, format="BMP")
        print(f"Wrote {out / name}")


if __name__ == "__main__":
    main()
