#!/usr/bin/env python3
"""Tests scripts/changelog-release.py, which the release workflow uses to move Unreleased under the new version.

Usage: python3 scripts/changelog-release.test.py   (ci.yml runs it; it takes well under a second)
"""
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True  # no __pycache__ next to the scripts

spec = importlib.util.spec_from_file_location(
    "changelog_release", os.path.join(os.path.dirname(os.path.abspath(__file__)), "changelog-release.py"))
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)

HEAD = "# Changelog\n\nIntro.\n\n"
REPO = "IAMichan/nook"


def release(version, released, current, date="2026-11-16"):
    return changelog.release(version, date, released, current, REPO)


class BetaRelease(unittest.TestCase):
    RELEASED = HEAD + """## Unreleased

### Added

- First feature.

- Second feature, written over
  two lines.

  With a second paragraph.

### Fixed

- A fix.
- Another fix.

## [0.1.0-beta.1] - 2026-10-23

First public beta.

[0.1.0-beta.1]: https://github.com/IAMichan/nook/releases/tag/v0.1.0-beta.1
"""

    def test_moves_the_released_entries_under_the_version(self):
        text, warnings = release("0.1.0-beta.2", self.RELEASED, self.RELEASED)
        self.assertEqual(warnings, [])
        self.assertEqual(text, HEAD + """## Unreleased

## [0.1.0-beta.2] - 2026-11-16

### Added

- First feature.

- Second feature, written over
  two lines.

  With a second paragraph.

### Fixed

- A fix.

- Another fix.

## [0.1.0-beta.1] - 2026-10-23

First public beta.

[0.1.0-beta.2]: https://github.com/IAMichan/nook/releases/tag/v0.1.0-beta.2
[0.1.0-beta.1]: https://github.com/IAMichan/nook/releases/tag/v0.1.0-beta.1
""")

    def test_an_entry_merged_during_the_build_stays_unreleased(self):
        current = self.RELEASED.replace("- A fix.\n", "- A fix.\n- Merged while building.\n")
        text, _ = release("0.1.0-beta.2", self.RELEASED, current)
        unreleased, rest = text.split("## [0.1.0-beta.2]")
        self.assertIn("### Fixed\n\n- Merged while building.\n", unreleased)
        self.assertNotIn("### Added", unreleased)
        self.assertNotIn("Merged while building", rest)

    def test_an_entry_edited_after_the_release_stays_and_warns(self):
        current = self.RELEASED.replace("- First feature.", "- First feature, now better.")
        text, warnings = release("0.1.0-beta.2", self.RELEASED, current)
        unreleased, rest = text.split("## [0.1.0-beta.2]")
        self.assertIn("First feature, now better.", unreleased)
        self.assertIn("- First feature.\n", rest)
        self.assertEqual(len(warnings), 1)

    def test_running_twice_changes_nothing(self):
        once, _ = release("0.1.0-beta.2", self.RELEASED, self.RELEASED)
        twice, warnings = release("0.1.0-beta.2", self.RELEASED, once)
        self.assertEqual(once, twice)
        self.assertIn("already has a section", warnings[0])

    def test_a_release_without_entries_still_gets_its_section(self):
        empty = HEAD + "## Unreleased\n\n## [0.1.0-beta.1] - 2026-10-23\n\nFirst.\n"
        text, _ = release("0.1.0-beta.2", empty, empty)
        self.assertIn(f"## [0.1.0-beta.2] - 2026-11-16\n\n{changelog.NOTHING}\n\n## [0.1.0-beta.1]", text)

    def test_line_breaks_do_not_make_an_entry_different(self):
        current = self.RELEASED.replace("- First feature.", "- First\n  feature.")
        _, warnings = release("0.1.0-beta.2", self.RELEASED, current)
        self.assertEqual(warnings, [])


class StableRelease(unittest.TestCase):
    CURRENT = HEAD + """## Unreleased

### Added

- After the beta.

## [0.2.0-beta.2] - 2026-11-10

### Fixed

- Fix in beta 2.

## [0.2.0-beta.1] - 2026-11-01

### Added

- Feature in beta 1.

### Fixed

- Fix in beta 1.

## [0.1.0] - 2026-10-23

- Old.

[0.2.0-beta.2]: https://github.com/IAMichan/nook/releases/tag/v0.2.0-beta.2
[0.2.0-beta.1]: https://github.com/IAMichan/nook/releases/tag/v0.2.0-beta.1
[0.1.0]: https://github.com/IAMichan/nook/releases/tag/v0.1.0
"""
    # The newest beta's commit, built before its own move landed: its entries were still under Unreleased.
    RELEASED = HEAD + "## Unreleased\n\n### Fixed\n\n- Fix in beta 2.\n"

    def test_folds_the_betas_into_one_section(self):
        text, warnings = release("0.2.0", self.RELEASED, self.CURRENT, date="2026-11-20")
        self.assertEqual(warnings, [])
        self.assertEqual(text, HEAD + """## Unreleased

### Added

- After the beta.

## [0.2.0] - 2026-11-20

### Added

- Feature in beta 1.

### Fixed

- Fix in beta 2.

- Fix in beta 1.

## [0.1.0] - 2026-10-23

- Old.

[0.2.0]: https://github.com/IAMichan/nook/releases/tag/v0.2.0
[0.1.0]: https://github.com/IAMichan/nook/releases/tag/v0.1.0
""")


if __name__ == "__main__":
    unittest.main()
