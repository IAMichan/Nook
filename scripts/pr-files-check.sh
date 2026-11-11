#!/usr/bin/env bash
# Rejects files a pull request should not commit (.github/workflows/ci.yml, job "Committed files").
#
# Usage: scripts/pr-files-check.sh < added-or-modified-files
#   Reads one path per line (relative to the repository root, files present in the working tree).
#
# Coding agents in particular leave things behind: build logs, test result bundles, screenshots meant as PR evidence,
# Finder metadata. Evidence belongs in the pull request description (drag the image into GitHub) or in `.scratch/`,
# which git ignores. Large files bloat every clone forever, even after they are deleted again.
set -euo pipefail

MAX_BYTES=$((2 * 1024 * 1024))

# Directories that may hold large vendored or media files on purpose.
LARGE_OK=(apps/macos/Resources/ docs/assets/)

problems=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in
    *.log | *.xcresult/* | */.DS_Store | .DS_Store | .scratch/* | */DerivedData/* | .derived-data/* | */xcuserdata/*)
      echo "::error file=$file::Generated file: remove it from the pull request (keep evidence in the PR description or .scratch/)."
      problems=$((problems + 1))
      continue
      ;;
  esac
  [ -f "$file" ] || continue
  size=$(wc -c <"$file" | tr -d ' ')
  if [ "$size" -gt "$MAX_BYTES" ]; then
    allowed=false
    for prefix in "${LARGE_OK[@]}"; do
      [[ "$file" == "$prefix"* ]] && allowed=true
    done
    if [ "$allowed" = false ]; then
      echo "::error file=$file::$((size / 1024)) KiB is over the $((MAX_BYTES / 1024 / 1024)) MiB limit. Upload media to the PR description instead, or add the directory to LARGE_OK in scripts/pr-files-check.sh with a reason."
      problems=$((problems + 1))
    fi
  fi
done

if [ "$problems" -gt 0 ]; then
  echo "$problems file(s) should not be committed."
  exit 1
fi
echo "No generated or oversized files."
