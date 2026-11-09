#!/usr/bin/env python3
"""Builds the Nook website: fills the shared partials into every page in src/ and writes the result next to this file.

Markers a page in src/ can use:
  <!-- @head title="…" desc="…" -->   the document head with the shared stylesheet
  <!-- @nav -->                        the top navigation
  <!-- @sprite -->                     the shared SVG icons (agent marks, folder, branch, pull request)
  <!-- @apple -->                      the Apple logo for download buttons
  <!-- @footer -->                     the footer, the shared script, and the end of the document

Run it after changing anything in src/ or _partials/:  python3 site/build.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent
PARTIALS = ROOT / "_partials"


def partial(name: str) -> str:
    return (PARTIALS / name).read_text().rstrip("\n")


def build(page: pathlib.Path) -> str:
    text = page.read_text()

    def head(match: re.Match) -> str:
        return partial("head.html").replace("{{TITLE}}", match["title"]).replace("{{DESC}}", match["desc"])

    text = re.sub(r'<!-- @head title="(?P<title>[^"]*)" desc="(?P<desc>[^"]*)" -->', head, text)
    text = text.replace("<!-- @nav -->", partial("nav.html"))
    text = text.replace("<!-- @sprite -->", partial("sprite.html"))
    text = text.replace("<!-- @apple -->", partial("apple.svg.html"))
    text = text.replace(
        "<!-- @footer -->",
        partial("footer.html") + '\n<script src="assets/nook.js"></script>',
    )
    if "<!-- @" in text:
        raise SystemExit(f"{page.name}: unknown marker left in the page")
    return text


def main() -> None:
    pages = sorted((ROOT / "src").glob("*.html"))
    for page in pages:
        (ROOT / page.name).write_text(build(page))
        print(f"built {page.name}")


if __name__ == "__main__":
    main()
