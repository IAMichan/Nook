#!/usr/bin/env python3
"""Moves the Unreleased entries of CHANGELOG.md that a release shipped under that release's version.

Usage: scripts/changelog-release.py VERSION DATE RELEASED [CHANGELOG]
  VERSION   the version without the `v`: 0.1.1-beta.4 or 0.1.1
  DATE      the release date, YYYY-MM-DD
  RELEASED  CHANGELOG.md as it was in the released commit (`git show <commit>:CHANGELOG.md > released.md`)
  CHANGELOG the file to change in place (default CHANGELOG.md), normally main's newer copy

The release workflow (`changelog` job in .github/workflows/release.yml) runs it once the release is public, so a
maintainer never moves the section by hand. Only the entries that were under Unreleased in the released commit move:
an entry merged into main while the release was building stays under Unreleased for the next one. An entry edited on
main after the released commit stays under Unreleased too, and the script warns about it.

A stable release (no `-` suffix) is built from its newest beta, so it gathers the entries of every beta of that version
into one section and drops the beta sections and their links: the stable section is what changed since the previous
stable version. Running it again for a version that already has a section changes nothing.

Tests: scripts/changelog-release.test.py.
"""
import os
import re
import sys

KNOWN_ORDER = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"]
NOTHING = "Only internal changes; the release page lists them."
VERSION_HEADING = re.compile(r"^## \[([^\]]+)\]")
LINK_REF = re.compile(r"^\[([^\]]+)\]: \S+")


def split_sections(lines):
    """Splits the file into the text before the first `## ` heading, the `## ` sections, and the link references at
    the end. Each section is [heading, body lines]."""
    head, sections, links = [], [], []
    end = len(lines)
    while end > 0 and (not lines[end - 1].strip() or LINK_REF.match(lines[end - 1])):
        end -= 1
    links = [line for line in lines[end:] if line.strip()]
    for line in lines[:end]:
        if line.startswith("## "):
            sections.append([line, []])
        elif sections:
            sections[-1][1].append(line)
        else:
            head.append(line)
    return head, sections, links


def entry_spans(body):
    """Finds the entries of a section body: [(subsection, start, end)], where body[start:end] is the entry without
    trailing blank lines and subsection is the `### ` name above it (None before the first). An entry is a `- ` bullet
    with its continuation lines (indented, also after a blank line), or a paragraph."""
    spans, name, index = [], None, 0
    while index < len(body):
        line = body[index]
        if line.startswith("### "):
            name = line[4:].strip()
            index += 1
            continue
        if not line.strip():
            index += 1
            continue
        end = index + 1
        while end < len(body):
            nxt = body[end]
            if nxt.startswith("### ") or nxt.startswith("- "):
                break
            if not nxt.strip():
                after = end
                while after < len(body) and not body[after].strip():
                    after += 1
                if after < len(body) and body[after].startswith(" "):
                    end = after
                    continue
                break
            end += 1
        spans.append((name, index, end))
        index = end
    return spans


def split_blocks(body):
    """A section body as [(subsection, [entry])], an entry being its lines, in the order they appear."""
    groups = []
    for name, start, end in entry_spans(body):
        if not groups or groups[-1][0] != name:
            groups.append((name, []))
        groups[-1][1].append(body[start:end])
    return groups


def key(entry):
    """Two entries are the same when their words are, whatever the line breaks."""
    return " ".join(" ".join(entry).split())


def find_section(sections, name):
    for index, (heading, _) in enumerate(sections):
        if heading[3:].strip() == name or heading.startswith(f"## [{name}]"):
            return index
    return None


def render(groups):
    """The body of a section: its entries by subsection (Keep a Changelog's order first), a blank line between
    entries, so a list reads the same however it was written."""
    names = list(dict.fromkeys(name for name, _ in groups))
    order = [None] + [n for n in KNOWN_ORDER if n in names] + [n for n in names if n not in KNOWN_ORDER and n is not None]
    merged, seen = {}, set()
    for name, entries in groups:
        for entry in entries:
            if key(entry) not in seen:  # a stable release can meet the same entry in a beta and in Unreleased
                seen.add(key(entry))
                merged.setdefault(name, []).append(entry)
    body = [""]
    for name in order:
        entries = merged.get(name) or []
        if not entries:
            continue
        if name is not None:
            body += [f"### {name}", ""]
        for entry in entries:
            body += entry + [""]
    if body == [""]:
        body += [NOTHING, ""]
    return body


def remove_entries(body, keys):
    """Drops the entries whose key is in `keys` from a section body, keeping every other line as it was written, and
    drops a `### ` subsection that is left empty."""
    gone = set()
    for _, start, end in entry_spans(body):
        if key(body[start:end]) in keys:
            gone.update(range(start, end))
    out = [line for i, line in enumerate(body) if i not in gone]
    result = []
    for i, line in enumerate(out):
        if line.startswith("### "):
            following = next((x for x in out[i + 1:] if x.strip()), None)
            if following is None or following.startswith("### "):
                continue
        if not line.strip() and result and not result[-1].strip():
            continue  # the blank lines a removal left behind
        result.append(line)
    while result and not result[-1].strip():
        result.pop()
    while result and not result[0].strip():
        result.pop(0)
    return [""] + result + ([""] if result else [])


def release(version, date, released_text, changelog_text, repository):
    """Returns the new changelog text and the warnings."""
    lines = changelog_text.splitlines()
    head, sections, links = split_sections(lines)
    if find_section(sections, version) is not None:
        return changelog_text, [f"CHANGELOG.md already has a section for {version}; nothing to do."]
    unreleased = find_section(sections, "Unreleased")
    if unreleased is None:
        raise SystemExit("CHANGELOG.md has no `## Unreleased` section.")

    _, released_sections, _ = split_sections(released_text.splitlines())
    released_index = find_section(released_sections, "Unreleased")
    shipped = split_blocks(released_sections[released_index][1]) if released_index is not None else []

    warnings = []
    current_keys = {key(entry) for _, entries in split_blocks(sections[unreleased][1]) for entry in entries}
    moved = set()
    for _, entries in shipped:
        for entry in entries:
            moved.add(key(entry))

    groups = list(shipped)
    drop = set()
    stable = "-" not in version
    if stable:
        # Every beta of this version is folded into the stable section; the entries of the betas came first.
        prefix = f"{version}-"
        betas = [i for i, (heading, _) in enumerate(sections)
                 if (m := VERSION_HEADING.match(heading)) and m.group(1).startswith(prefix)]
        folded = []
        for i in betas:
            folded += split_blocks(sections[i][1])
        groups = folded + groups
        drop = set(betas)
        beta_names = {VERSION_HEADING.match(sections[i][0]).group(1) for i in betas}
        links = [link for link in links if LINK_REF.match(link).group(1) not in beta_names]
        already = {key(entry) for _, entries in folded for entry in entries}
        stale = [k for k in moved if k not in current_keys and k not in already]
    else:
        stale = [k for k in moved if k not in current_keys]
    for k in stale:
        warnings.append(f"Changed on main after the release, so it also stays under Unreleased: {k[:100]}")

    sections[unreleased][1] = remove_entries(sections[unreleased][1], moved)
    new_section = [f"## [{version}] - {date}", render(groups)]
    sections = [s for i, s in enumerate(sections) if i not in drop]
    unreleased = find_section(sections, "Unreleased")
    sections.insert(unreleased + 1, new_section)

    url = f"https://github.com/{repository}/releases/tag/v{version}"
    links = [f"[{version}]: {url}"] + links

    out = list(head)
    for heading, body in sections:
        out.append(heading)
        out += body
    while out and not out[-1].strip():
        out.pop()
    out += [""] + links
    return "\n".join(out) + "\n", warnings


def main(argv):
    if len(argv) not in (4, 5):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    version, date, released_path = argv[1:4]
    path = argv[4] if len(argv) == 5 else "CHANGELOG.md"
    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", version):
        print(f"'{version}' is not a version like 0.1.0-beta.1 or 1.0.0 (without the v).", file=sys.stderr)
        return 2
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        print(f"'{date}' is not a date like 2026-11-16.", file=sys.stderr)
        return 2
    with open(released_path, encoding="utf-8") as handle:
        released = handle.read()
    with open(path, encoding="utf-8") as handle:
        current = handle.read()
    repository = os.environ.get("GITHUB_REPOSITORY", "IAMichan/nook")
    text, warnings = release(version, date, released, current, repository)
    for warning in warnings:
        print(f"::warning::{warning}" if os.environ.get("GITHUB_ACTIONS") else warning, file=sys.stderr)
    if text != current:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
