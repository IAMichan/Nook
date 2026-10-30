#!/usr/bin/env python3
"""Checks that a pull request description follows .github/pull_request_template.md.

Reads the description from the PR_BODY environment variable (or stdin) and exits non-zero with one line per
problem. Used by .github/workflows/pr-template.yml; run it locally with `PR_BODY="$(cat body.md)" ./scripts/pr-body-check.py`.
"""
import os
import re
import sys

REQUIRED = ["Summary", "Related issues", "Why", "Testing"]
ISSUE_LINK = re.compile(r"^\s*[-*]?\s*(Closes|Fixes|Resolves|Part of)\s+(\S+/\S+)?#\d+", re.IGNORECASE | re.MULTILINE)
NONE = re.compile(r"^\s*[-*]?\s*None\.?\s*$", re.IGNORECASE | re.MULTILINE)
CHECKED = re.compile(r"^\s*[-*]\s+\[[xX]\]", re.MULTILINE)
CHECKBOX = re.compile(r"^\s*[-*]\s+\[[ xX]\]")
NOTE_AFTER_BOX = re.compile(r"\s[—–]\s*\S|\.\s+(Not|Ran|Run|Passes|Passed|Fails|Failed)\b|:\s+(Not|N/A)\b")
ATTRIBUTION = re.compile(r"Generated with|Co-Authored-By", re.IGNORECASE)


def sections(body):
    """Maps each `## Heading` to the text below it, with HTML comments removed."""
    body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    found = {}
    current = None
    for line in body.splitlines():
        heading = re.match(r"^##\s+(.+?)\s*#*\s*$", line)
        if heading:
            current = heading.group(1).strip()
            found[current] = []
        elif current is not None:
            found[current].append(line)
    return {name: "\n".join(lines).strip() for name, lines in found.items()}


def testing_note(testing):
    """Whether the Testing section says how the change was tested, or that it was not, beyond the template's empty
    checklist: a line of its own, or words after a box ("- [ ] Verified in the macOS app — not yet"). A description
    written before anything ran (by a tool that only sees the diff) can say so honestly instead of ticking a box. The
    "Generated with" line at the end of a description does not count."""
    for line in testing.splitlines():
        text = line.strip()
        if not text or ATTRIBUTION.search(text):
            continue
        if not CHECKBOX.match(text) or NOTE_AFTER_BOX.search(text):
            return True
    return False


def problems(body):
    found = sections(body)
    errors = []
    for name in REQUIRED:
        if name not in found:
            errors.append(f"Missing section `## {name}`.")
        elif not found[name]:
            errors.append(f"Section `## {name}` is empty.")
    related = found.get("Related issues", "")
    if related and not (ISSUE_LINK.search(related) or NONE.search(related)):
        errors.append("`## Related issues` must list `Closes #123` / `Part of #123`, or say `None`.")
    testing = found.get("Testing", "")
    if testing and not (CHECKED.search(testing) or testing_note(testing)):
        errors.append("`## Testing` must tick a checkbox (`- [x]`) for what you verified, or say in a line of its own "
                      "what was run or not run.")
    return errors


if __name__ == "__main__":
    body = os.environ.get("PR_BODY")
    if body is None:
        body = sys.stdin.read()
    errors = problems(body)
    for error in errors:
        print(f"::error::{error}")
    if errors:
        print("Fill in the description from .github/pull_request_template.md and save it; this check runs again on edit.")
        sys.exit(1)
    print("Pull request description follows the template.")
