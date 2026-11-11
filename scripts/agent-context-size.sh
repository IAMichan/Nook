#!/bin/bash
# Prints the size in bytes of the text every coding agent reads before it starts on this repository:
# the root AGENTS.md and CLAUDE.md (docs/AGENTS.md is user documentation, not agent context), at the given revision (default: the working tree's HEAD). The last line is the total.
# agent-context-budget.yml compares the total of a pull request with the one on main.
#
#   scripts/agent-context-size.sh            sizes at HEAD
#   scripts/agent-context-size.sh origin/main
set -euo pipefail

REV="${1:-HEAD}"
total=0
while IFS= read -r path; do
  size="$(git cat-file -s "$REV:$path")"
  printf '%8d  %s\n' "$size" "$path"
  total=$((total + size))
done < <(git ls-tree -r --name-only "$REV" | grep -E '^(AGENTS|CLAUDE)\.md$' | sort)
printf '%8d  total\n' "$total"
