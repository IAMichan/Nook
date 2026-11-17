#!/usr/bin/env python3
"""Keeps the shared tracker docs in a layout where parallel pull requests rarely conflict.

Git reports a conflict when two branches change the same line or two touching lines, or both insert at the same
spot. Almost every Tauri pull request ticks an item in docs/WINDOWS-PARITY.md and adds or edits an entry in
docs/TAURI.md, so those two files used to conflict on nearly every merge. This layout avoids that:

- docs/WINDOWS-PARITY.md: a blank line between checklist items, so ticking neighbouring items merges cleanly.
- docs/TAURI.md: each `## ` section is a list of entries (`- Part. **Tauri:** status. **Where:** files`) sorted by
  part name and separated by blank lines, so a new entry goes into its own sorted spot instead of the end of the
  section, and editing a neighbouring entry merges cleanly.

Usage:
  scripts/docs-merge-layout.py          check; exits 1 and says what to fix (CI runs this)
  scripts/docs-merge-layout.py --fix    rewrite the files into the layout (also turns old tables into entries)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PARITY = ROOT / "docs" / "WINDOWS-PARITY.md"
TAURI = ROOT / "docs" / "TAURI.md"

CHECK_ITEM = re.compile(r"^- \[[ x]\] ")
ENTRY = re.compile(r"^- .*\*\*Tauri:\*\* ")
# Sections of TAURI.md that hold entries; the others (To do, Testing against fake services) are prose.
PROSE_SECTIONS = {"To do", "Testing against fake services"}


def sort_key(entry: str) -> str:
    """The part name without Markdown, lowercased: `ActionGate` and Sources card sort as actiongate and sources card."""
    text = entry[2:].split(" **Tauri:** ", 1)[0]
    return re.sub(r"[`*_\[\]()]", "", text).strip().lower()


def entry_from_row(row: str) -> str:
    cells = [c.strip() for c in row.strip().strip("|").split("|")]
    if len(cells) != 3:
        raise SystemExit(f"TAURI.md: expected 3 cells, got {len(cells)}: {row[:100]}")
    part, status, where = cells
    end = "" if part.endswith((".", "!", "?")) else "."
    return f"- {part}{end} **Tauri:** {status}. **Where:** {where}"


# MARK: WINDOWS-PARITY.md


def space_checklist(lines: list[str]) -> list[str]:
    out: list[str] = []
    for line in lines:
        if CHECK_ITEM.match(line) and out and CHECK_ITEM.match(out[-1]):
            out.append("")
        out.append(line)
    return out


def check_checklist(lines: list[str]) -> list[str]:
    return [
        f"docs/WINDOWS-PARITY.md:{i + 1}: put a blank line between checklist items"
        for i in range(1, len(lines))
        if CHECK_ITEM.match(lines[i]) and CHECK_ITEM.match(lines[i - 1])
    ]


# MARK: TAURI.md


def sections(lines: list[str]) -> list[tuple[str | None, list[str]]]:
    """Splits into (heading title, lines) blocks; the part before the first `## ` heading has title None."""
    blocks: list[tuple[str | None, list[str]]] = [(None, [])]
    for line in lines:
        if line.startswith("## "):
            blocks.append((line[3:].strip(), [line]))
        else:
            blocks[-1][1].append(line)
    return blocks


def layout_section(body: list[str]) -> list[str]:
    """Turns a table into entries (once), then sorts the entries and spaces them; prose around them stays in place."""
    converted: list[str] = []
    for line in body:
        if line.startswith("| Part") or re.match(r"^\|-", line):
            continue
        converted.append(entry_from_row(line) if line.startswith("|") else line)
    first = next((i for i, line in enumerate(converted) if ENTRY.match(line)), None)
    if first is None:
        return converted
    last = max(i for i, line in enumerate(converted) if ENTRY.match(line))
    entries = sorted((line for line in converted[first : last + 1] if line.strip()), key=sort_key)
    stray = [line for line in entries if not ENTRY.match(line)]
    if stray:
        raise SystemExit(f"TAURI.md: keep each entry on one line, with nothing else between entries: {stray[0][:100]}")
    spaced: list[str] = []
    for entry in entries:
        if spaced:
            spaced.append("")
        spaced.append(entry)
    return converted[:first] + spaced + converted[last + 1 :]


def layout_tauri(lines: list[str]) -> list[str]:
    out: list[str] = []
    for title, body in sections(lines):
        out += body if title is None or title in PROSE_SECTIONS else layout_section(body)
    return out


def check_tauri(lines: list[str]) -> list[str]:
    problems: list[str] = []
    if any(line.startswith("| Part") for line in lines):
        problems.append("docs/TAURI.md: a table is back; write each row as an entry (run this script with --fix)")
    if layout_tauri(lines) != lines:
        problems.append(
            "docs/TAURI.md: entries must be sorted by part name with a blank line between them, so parallel pull "
            "requests don't all append to the end of a section (run scripts/docs-merge-layout.py --fix)"
        )
    return problems


def main() -> int:
    fix = "--fix" in sys.argv[1:]
    parity = PARITY.read_text().split("\n")
    tauri = TAURI.read_text().split("\n")
    if fix:
        PARITY.write_text("\n".join(space_checklist(parity)))
        TAURI.write_text("\n".join(layout_tauri(tauri)))
        return 0
    problems = check_checklist(parity) + check_tauri(tauri)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
