#!/bin/sh
# Prints the tag of the next Nook beta release, from the release tags in this repository.
# Used by .github/workflows/release.yml; run it locally to see what the next release would be called.
#
#   scripts/next-release-tag.sh [beta|patch|minor|major]
#
#   beta   next beta of the current version: v0.1.0-beta.1 → v0.1.0-beta.2 (the default)
#   patch  first beta of the next patch version: v0.1.0-beta.4 → v0.1.1-beta.1
#   minor  first beta of the next minor version: v0.1.3-beta.2 → v0.2.0-beta.1
#   major  first beta of the next major version: v0.4.0-beta.1 → v1.0.0-beta.1
#
# Without release tags, the current version is MARKETING_VERSION in apps/macos/project.yml. When the current version
# was already released without a beta suffix, `beta` moves on to the next patch version.
set -eu
BUMP="${1:-beta}"
cd "$(dirname "$0")/.."

# Versions in release tags (v1.2.3 or v1.2.3-beta.4), highest last.
BASE="$(git tag -l 'v*' | sed -n 's/^v\([0-9]*\.[0-9]*\.[0-9]*\)\(-beta\.[0-9]*\)\{0,1\}$/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
if [ -z "$BASE" ]; then
  BASE="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9]*\.[0-9]*\.[0-9]*\)"\{0,1\} *$/\1/p' apps/macos/project.yml | head -n 1)"
fi
[ -n "$BASE" ] || { echo "next-release-tag: no version found" >&2; exit 1; }

MAJOR="${BASE%%.*}"
REST="${BASE#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

case "$BUMP" in
  beta)
    if git rev-parse -q --verify "refs/tags/v$BASE" >/dev/null; then PATCH=$((PATCH + 1)); fi ;;
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  *) echo "next-release-tag: unknown bump '$BUMP' (beta, patch, minor or major)" >&2; exit 1 ;;
esac
VERSION="$MAJOR.$MINOR.$PATCH"

# Highest beta number of this version so far.
LAST="$(git tag -l "v$VERSION-beta.*" | sed -n "s/^v$VERSION-beta\.\([0-9]*\)$/\1/p" | sort -n | tail -n 1)"
echo "v$VERSION-beta.$(( ${LAST:-0} + 1 ))"
