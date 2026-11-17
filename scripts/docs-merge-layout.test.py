#!/usr/bin/env python3
"""Tests scripts/docs-merge-layout.py, which keeps docs/TAURI.md and docs/WINDOWS-PARITY.md in a layout that merges.

Usage: python3 scripts/docs-merge-layout.test.py   (ci.yml runs it; it takes well under a second)
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # no __pycache__ next to the scripts

spec = importlib.util.spec_from_file_location(
    "docs_merge_layout", os.path.join(os.path.dirname(os.path.abspath(__file__)), "docs-merge-layout.py"))
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)

TABLE = """# Title

## Core

Intro.

| Part (Mac) | Tauri | Where |
|---|---|---|
| `Zeta` thing | ✓ | `z.rs` |
| Alpha part. | ◐ (not run) | `a.rs` |

## To do

| Part | not | an entry |
"""


class Layout(unittest.TestCase):
    def test_turns_a_table_into_sorted_spaced_entries(self):
        out = layout.layout_tauri(TABLE.split("\n"))
        self.assertEqual(
            out[4:9],
            [
                "Intro.",
                "",
                "- Alpha part. **Tauri:** ◐ (not run). **Where:** `a.rs`",
                "",
                "- `Zeta` thing. **Tauri:** ✓. **Where:** `z.rs`",
            ],
        )
        # Prose sections are left alone.
        self.assertIn("| Part | not | an entry |", out)

    def test_layout_is_stable(self):
        once = layout.layout_tauri(TABLE.split("\n"))
        self.assertEqual(layout.layout_tauri(once), once)

    def test_check_finds_an_entry_appended_out_of_order(self):
        lines = layout.layout_tauri(TABLE.split("\n"))
        at = lines.index("- `Zeta` thing. **Tauri:** ✓. **Where:** `z.rs`")
        lines[at + 1 : at + 1] = ["", "- Beta. **Tauri:** ○. **Where:** `b.rs`"]
        self.assertTrue(layout.check_tauri(lines))

    def test_checklist_items_get_a_blank_line_between_them(self):
        lines = ["## 1", "", "- [ ] **A-1** one", "- [x] **A-2** two", "", "Text."]
        spaced = layout.space_checklist(lines)
        self.assertEqual(spaced, ["## 1", "", "- [ ] **A-1** one", "", "- [x] **A-2** two", "", "Text."])
        self.assertTrue(layout.check_checklist(lines))
        self.assertFalse(layout.check_checklist(spaced))


class Merges(unittest.TestCase):
    """The point of the layout: two branches that tick neighbouring items, or edit neighbouring entries, merge."""

    def merge(self, base, ours, theirs):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for name, text in (("ours", ours), ("base", base), ("theirs", theirs)):
                path = os.path.join(d, name)
                with open(path, "w") as f:
                    f.write("\n".join(text) + "\n")
                paths.append(path)
            return subprocess.run(["git", "merge-file", "-p", *paths], capture_output=True).returncode

    def test_neighbouring_ticks_merge(self):
        base = layout.space_checklist(["- [ ] **A-1** one", "- [ ] **A-2** two"])
        ours = [line.replace("[ ] **A-1**", "[x] **A-1**") for line in base]
        theirs = [line.replace("[ ] **A-2**", "[x] **A-2**") for line in base]
        self.assertEqual(self.merge(base, ours, theirs), 0)

    def test_new_entries_in_different_sorted_spots_merge(self):
        base = layout.layout_tauri(TABLE.split("\n"))
        ours = layout.layout_tauri(base[:6] + ["- Beta. **Tauri:** ✓. **Where:** `b.rs`"] + base[6:])
        theirs = layout.layout_tauri(base[:6] + ["- `Zz` last. **Tauri:** ✓. **Where:** `zz.rs`"] + base[6:])
        self.assertEqual(self.merge(base, ours, theirs), 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
