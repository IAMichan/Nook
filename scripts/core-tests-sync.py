#!/usr/bin/env python3
"""Lays out the package scripts/core-tests.sh builds, and picks the tests a change needs (`--changed`).

    core-tests-sync.py ROOT WORK [--changed BASE]

ROOT is apps/macos, WORK the package folder. EXCLUDE_SOURCES and EXCLUDE_TESTS (newline-separated, from the environment)
leave out what needs Apple-only frameworks.

Files are only rewritten when their content changes, so the package in WORK builds incrementally: the second run compiles
only what changed since the first.

With --changed, only the test files a change can affect go into the package. BASE is a git revision ("auto": the
merge base with origin's default branch); the change is everything from there to the working tree, untracked files
included. A test file is picked when
  - it changed itself;
  - it names a type (or, for a file of only extensions, a function) declared in a core source that changed;
  - it reads the app's sources from disk (NOOK_MACOS_ROOT) and anything under apps/macos or packages/protocol changed;
plus the test files that declare helpers the picked ones use. A change to the package's own setup (project.yml, the
scripts) or a deleted core source picks everything.

Prints the selected test files and their classes, then `all`, `some` or `none` on its last line for the caller.

It also says on stderr which changed app sources this package does not compile at all (views, AppKit, the excluded
Apple-only files), with or without --changed: no core test can catch a mistake there, only `scripts/xcode.sh build`.
"""
import os
import re
import subprocess
import sys

root, work = sys.argv[1], sys.argv[2]
base = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == "--changed" else None
repo = os.path.normpath(os.path.join(root, "..", ".."))
excluded_sources = set(filter(None, os.environ.get("EXCLUDE_SOURCES", "").split("\n")))
excluded_tests = set(filter(None, os.environ.get("EXCLUDE_TESTS", "").split("\n")))
tests_dir = os.path.join(root, "Tests", "NookTests")

# The sources the NookTests target lists in project.yml.
text = open(os.path.join(root, "project.yml")).read()
block = text[text.index("  NookTests:"):]
block = re.split(r"\n  # iPhone companion|\n  NookCompanion:|\nschemes:", block)[0]
# The I18n tables need SwiftUI; `tr` is shimmed by core-tests.sh instead.
sources = [p for p in re.findall(r"- path: (\S+)", block)
           if p.endswith(".swift") and p not in excluded_sources and not p.startswith("Core/I18n")]
tests = sorted(name[:-6] for name in os.listdir(tests_dir)
               if name.endswith(".swift") and name[:-6] not in excluded_tests)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def strip_comments(source):
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)


TYPE_DECL = re.compile(r"\b(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)")
TOP_FUNC = re.compile(r"^(?:(?:public|internal|@\w+(?:\([^)]*\))?)\s+)*func\s+([A-Za-z_]\w*)", re.M)
ANY_FUNC = re.compile(r"^\s*(?:(?:public|internal|static|class|mutating|nonisolated|@\w+(?:\([^)]*\))?)\s+)*"
                      r"(?:func|var|let)\s+([A-Za-z_]\w*)", re.M)
PRIVATE_LINE = re.compile(r"^\s*(?:@\w+\s+)*(?:private|fileprivate)\b")


def source_names(source):
    """What tests use a core source by: its types, else (a file of extensions) its functions and properties."""
    source = strip_comments(source)
    names = set(TYPE_DECL.findall(source)) | set(TOP_FUNC.findall(source))
    if not TYPE_DECL.search(source):
        names |= {m.group(1) for m in ANY_FUNC.finditer(source)
                  if not PRIVATE_LINE.match(source[source.rfind("\n", 0, m.start()) + 1:m.end()])}
    # Too short or too common to say anything about who uses them.
    return {n for n in names if len(n) >= 4 and n not in {"init", "body", "description", "rawValue", "shared"}}


def test_exports(source):
    """What a test file offers other test files: its non-private top-level declarations and extension members."""
    source = strip_comments(source)
    names, in_extension = set(), False
    for line in source.split("\n"):
        if line.startswith("}"):
            in_extension = False
            continue
        if line[:1] and not line[:1].isspace():
            in_extension = line.lstrip("@").split(" ", 1)[0] == "extension" or " extension " in f" {line} "
            if not PRIVATE_LINE.match(line):
                match = re.search(r"\b(?:class|struct|enum|protocol|actor|typealias|func|let|var)\s+([A-Za-z_]\w*)", line)
                if match and not match.group(1).endswith("Tests"):
                    names.add(match.group(1))
        elif in_extension and not PRIVATE_LINE.match(line):
            match = re.match(r"\s+(?:(?:static|public|internal|mutating|@\w+)\s+)*(?:func|var|let)\s+([A-Za-z_]\w*)", line)
            if match:
                names.add(match.group(1))
    return {n for n in names if len(n) >= 3}


def mentions(text, names):
    if not names:
        return False
    pattern = re.compile(r"\b(?:" + "|".join(re.escape(n) for n in sorted(names)) + r")\b")
    return pattern.search(text) is not None


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def changed_files(base):
    if base == "auto":
        base = None
        for ref in ("origin/HEAD", "origin/main", "main"):
            try:
                git("rev-parse", "--verify", "--quiet", ref)
                base = ref
                break
            except subprocess.CalledProcessError:
                pass
        if base is None:
            return None
    try:
        start = git("merge-base", base, "HEAD").strip()
    except subprocess.CalledProcessError:
        start = base
    files = git("diff", "--name-only", start).split("\n") + git("ls-files", "--others", "--exclude-standard").split("\n")
    return sorted(set(f for f in files if f))


def uncovered(changed):
    """The changed Swift sources of the app that this package does not compile (the base is `auto` without --changed)."""
    macos = os.path.relpath(root, repo) + "/"
    compiled = {os.path.normpath(os.path.join(macos, p)) for p in sources}
    return [path for path in changed
            if path.endswith(".swift") and path.startswith(macos) and not path.startswith(macos + "Tests/")
            and path not in compiled and os.path.exists(os.path.join(repo, path))]


def select(changed):
    """The test files `changed` needs, or None for all of them."""
    macos = os.path.relpath(root, repo) + "/"
    everything = {macos + "project.yml", "scripts/core-tests.sh", "scripts/core-tests-sync.py"}
    source_paths = {os.path.normpath(os.path.join(macos, p)): p for p in sources}
    test_texts = {name: read(os.path.join(tests_dir, name + ".swift")) for name in tests}
    picked, names, reads_sources = set(), set(), False
    for path in changed:
        if path in everything:
            return None
        if path.startswith(macos) or path.startswith("packages/protocol/"):
            reads_sources = True
        if path.startswith(macos + "Tests/NookTests/") and path.endswith(".swift"):
            name = os.path.basename(path)[:-6]
            if name in test_texts:
                picked.add(name)
        elif path in source_paths:
            full = os.path.join(repo, path)
            if not os.path.exists(full):
                return None  # who used what it declared is no longer visible
            names |= source_names(read(full))
            # Its own test file, by convention.
            own = os.path.basename(path)[:-6] + "Tests"
            if own in test_texts:
                picked.add(own)
    for name, text in test_texts.items():
        body = strip_comments(text)
        if mentions(body, names) or (reads_sources and "NOOK_MACOS_ROOT" in text):
            picked.add(name)
    # Helpers in other test files that the picked ones use.
    exports = {name: test_exports(text) for name, text in test_texts.items()}
    frontier = set(picked)
    while frontier:
        body = "\n".join(strip_comments(test_texts[n]) for n in frontier)
        frontier = {name for name in test_texts if name not in picked and mentions(body, exports[name])}
        picked |= frontier
    # Files without tests are shared helpers: they always come along.
    picked |= {name for name, text in test_texts.items() if "func test" not in text}
    return picked


def write_if_changed(path, content):
    if read(path) != content or not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)


def sync(folder, wanted):
    """Makes `folder` hold exactly `wanted` ({name: ("link", target) | ("text", content)}), touching only what differs."""
    os.makedirs(folder, exist_ok=True)
    for name in os.listdir(folder):
        if name not in wanted:
            os.remove(os.path.join(folder, name))
    for name, (kind, value) in wanted.items():
        path = os.path.join(folder, name)
        if kind == "link":
            if os.path.islink(path) and os.readlink(path) == value:
                continue
            if os.path.lexists(path):
                os.remove(path)
            os.symlink(value, path)
        else:
            if os.path.islink(path):
                os.remove(path)
            write_if_changed(path, value)


selection = None
try:
    changed = changed_files(base or "auto")
except (OSError, subprocess.CalledProcessError) as error:
    if base is not None:
        detail = (getattr(error, "stderr", None) or str(error)).strip()
        sys.exit(f"core-tests: cannot list the change since {base}: {detail}")
    changed = None  # not a Git checkout: the full run needs no change list
if base is not None and changed is not None:
    selection = select(changed)
missing = uncovered(changed or [])
if missing:
    shown = " ".join(missing[:5]) + (f" (+{len(missing) - 5} more)" if len(missing) > 5 else "")
    print(f"note: the core tests do not compile {len(missing)} changed file(s): {shown}\n"
          "      check those with ./scripts/xcode.sh build (or ./scripts/xcode.sh test)", file=sys.stderr)

sdir = os.path.join(work, "Sources", "Core")
wanted_sources = {
    # Paths are relative to apps/macos; shared ones start with ../../packages. Drop the ../ so no name starts with a dot.
    p.replace("../", "").replace("/", "__"): ("link", os.path.normpath(os.path.join(root, p))) for p in sources}
# Written by core-tests.sh itself.
wanted_sources["PortabilityShims.swift"] = ("text", read(os.path.join(sdir, "PortabilityShims.swift")))
sync(sdir, wanted_sources)

linux = os.uname().sysname != "Darwin"
wanted_tests = {}
for name in (tests if selection is None else sorted(selection)):
    content = "@testable import Core\n" + read(os.path.join(tests_dir, name + ".swift"))
    # Linux's test discovery cannot call a synchronous test on the main actor (it aborts the whole run): there they are async.
    if linux and re.search(r"^\s*@MainActor\s*$", content, re.M):
        content = re.sub(r"^([ \t]*(?:@MainActor[ \t]+)?func test\w*\(\))([ \t]+throws)?[ \t]*\{",
                         lambda m: f"{m.group(1)} async{m.group(2) or ''} {{", content, flags=re.M)
    wanted_tests[name + ".swift"] = ("text", content)
sync(os.path.join(work, "Tests", "CoreTests"), wanted_tests)

if selection is None:
    print("all")
else:
    real = sorted(n for n in selection if "func test" in read(os.path.join(tests_dir, n + ".swift")))
    total = sum(1 for n in tests if "func test" in read(os.path.join(tests_dir, n + ".swift")))
    print(f"selected {len(real)}/{total} test files: {' '.join(real)}" if real else "no core tests are affected")
    classes = sorted({c for n in real for c in re.findall(r"class\s+(\w+)\s*:\s*XCTestCase",
                                                           read(os.path.join(tests_dir, n + ".swift")))})
    print("test classes: " + "|".join(classes))
    print("some" if real else "none")
