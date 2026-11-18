#!/usr/bin/env python3
"""Makes the social cards (Open Graph images, 1200×630) in assets/og/: one per page in src/, with the page's heading.

It renders each card with headless Google Chrome and needs no other dependencies. Run it after changing a page's
<h1>, then run build.py:  python3 site/og.py && python3 site/build.py
"""
import html
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "assets" / "og"
CHROME = next(
    (p for p in (
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome") or "",
        shutil.which("chromium") or "",
    ) if p and pathlib.Path(p).exists()),
    None,
)

sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT))
from build import LABELS  # noqa: E402

CARD = """<!doctype html><html><head><meta charset="utf-8"><style>
:root{--paper:#F5F5F5;--t3:#949494;--t4:#5E5E5E}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1200px;height:630px;background:#000;overflow:hidden;color:var(--paper);
  font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
.glow{position:absolute;width:900px;height:900px;border-radius:50%;right:-380px;top:-420px;
  background:radial-gradient(circle,rgba(255,255,255,.10),rgba(255,255,255,0) 62%)}
.card{position:absolute;inset:0;padding:72px 84px;display:flex;flex-direction:column}
.brand{display:flex;align-items:center;gap:18px;font-size:34px;font-weight:600;letter-spacing:-.02em}
.mascot{width:56px;height:56px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;gap:8px;
  background:radial-gradient(circle at 35% 30%,#fff,#e4e4e8 70%,#cfcfd4)}
.mascot i{width:7px;height:17px;background:#050507;border-radius:99px}
.label{margin-left:auto;font-size:24px;color:var(--t3);font-weight:500;border-radius:99px;padding:10px 22px;
  box-shadow:inset 0 0 0 1.5px #262626}
h1{margin-top:auto;font-size:{{SIZE}}px;font-weight:600;letter-spacing:-.04em;line-height:1.02;max-width:1020px}
h1 span{color:var(--t4)}
.foot{margin-top:40px;display:flex;gap:28px;font-size:24px;color:var(--t3)}
.foot b{color:var(--paper);font-weight:500}
</style></head><body><div class="glow"></div><div class="card">
<div class="brand"><span class="mascot"><i></i><i></i></span>Nook{{LABEL}}</div>
<h1>{{HEADING}}</h1>
<div class="foot"><b>Free and open source</b><span>Local-first AI</span><span>Nothing happens without your yes</span></div>
</div></body></html>"""


def heading(page: pathlib.Path) -> str:
    m = re.search(r"<h1[^>]*>(.*?)</h1>", page.read_text(), re.S)
    if not m:
        raise SystemExit(f"{page.name}: no <h1>")
    # Keep the line break and the grey second line; drop everything else.
    inner = re.sub(r"<(?!/?span\b|br\b)[^>]+>", "", m[1])
    return re.sub(r'<span[^>]*>', "<span>", inner)


def main() -> None:
    if not CHROME:
        raise SystemExit("og.py needs Google Chrome or Chromium")
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for page in sorted((ROOT / "src").glob("*.html")):
            if page.stem not in LABELS:
                continue
            h = heading(page)
            plain = re.sub(r"<[^>]+>", "", h)
            size = 96 if len(plain) <= 40 else (84 if len(plain) <= 52 else 72)
            label = "" if page.stem == "index" else f'<span class="label">{html.escape(LABELS[page.stem])}</span>'
            card = CARD.replace("{{SIZE}}", str(size)).replace("{{LABEL}}", label).replace("{{HEADING}}", h)
            src = pathlib.Path(tmp) / f"{page.stem}.html"
            src.write_text(card)
            target = OUT / f"{page.stem}.png"
            subprocess.run(
                [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                 f"--user-data-dir={tmp}/profile", "--window-size=1200,630", f"--screenshot={target}", src.as_uri()],
                check=True, capture_output=True,
            )
            print(f"made assets/og/{page.stem}.png")


if __name__ == "__main__":
    main()
