#!/bin/bash
# Writes the release page for a macOS release (.github/workflows/release.yml) to stdout: the banner, the download
# button and the downloads right under it, the three install steps, and the change list folded away at the bottom, so
# nobody has to scroll past the changes to find the .dmg.
#
#   TAG=v0.1.0-beta.2 VERSION=0.1.0-beta.2 REPO=IAMichan/nook PRERELEASE=true NOTARIZED=false \
#     DMG=Nook-0.1.0-beta.2-macOS.dmg ZIP=Nook-0.1.0-beta.2-macOS.zip CHANGES=changes.md scripts/release-notes.sh
#
# CHANGES is a file with GitHub's generated notes (the "What's Changed" list); it may be missing or empty.
# GitHub keeps line breaks in a release's text, so every paragraph and list item below is one line.
set -euo pipefail
: "${TAG:?}" "${VERSION:?}" "${REPO:?}" "${DMG:?}" "${ZIP:?}"
PRERELEASE="${PRERELEASE:-false}"
NOTARIZED="${NOTARIZED:-false}"
CHANGES="${CHANGES:-}"

DOWNLOADS="https://github.com/$REPO/releases/download/$TAG"
BANNER="https://raw.githubusercontent.com/$REPO/$TAG/docs/assets/release-banner.png"

# "42 MB", from the file when it is here (in the workflow it is; a dry run elsewhere may not have it).
size_of() {
  [ -f "$1" ] || return 0
  local bytes
  bytes="$(wc -c < "$1" | tr -d ' ')"
  echo " · $(( (bytes + 524288) / 1048576 )) MB"
}

# The button: a shields.io badge in Nook's paper white on its near-black ink, with Apple's mark.
BUTTON="https://img.shields.io/badge/Download_for_Mac-.dmg$(size_of "$DMG" | sed 's/ · /_%C2%B7_/; s/ /_/g')-F5F5F5?style=for-the-badge&logo=apple&logoColor=0B0B0D&labelColor=F5F5F5&color=D6D6D6"

cat <<EOF
<p align="center">
  <img src="$BANNER" alt="Nook: your AI assistant and coding-agent command center, in the notch" width="900">
</p>

<p align="center">
  <a href="$DOWNLOADS/$DMG"><img src="$BUTTON" alt="Download Nook for Mac (.dmg)" height="44"></a>
</p>

<p align="center">
  <sub>Apple Silicon (M1 or newer) · macOS 15 Sequoia or newer</sub><br>
  <sub><a href="$DOWNLOADS/$ZIP">.zip instead</a>$(size_of "$ZIP") · <a href="$DOWNLOADS/SHA256SUMS.txt">SHA-256 checksums</a> · <a href="https://github.com/$REPO/releases">all releases</a></sub>
</p>

EOF

if [ "$PRERELEASE" = "true" ]; then
  cat <<EOF
> [!NOTE]
> This is a beta: expect rough edges, and please report problems in [Issues](https://github.com/$REPO/issues).

EOF
fi

cat <<EOF
## Install in three steps

1. **Open** \`$DMG\` and drag **Nook** onto **Applications**.
EOF
if [ "$NOTARIZED" = "true" ]; then
  echo "2. **Open Nook** from Applications. It lives in your notch and the menu bar (no Dock icon)."
else
  cat <<'EOF'
2. **Allow the first launch.** This build is not notarized by Apple yet, so macOS stops it once with "Apple could not verify…". Click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway** next to Nook. Or run this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Nook.app
   ```
EOF
fi
cat <<'EOF'
3. **Follow the setup.** It walks you through what to allow, step by step, and marks what is optional: Nook works without contacts, the microphone and the rest of that list.

<details>
<summary><b>Good to know</b></summary>

- Nook lives in your notch and the menu bar; there is no Dock icon.
- This build does not include the Telegram bridge or the chat helper (Signal, Messenger, Instagram, X, LinkedIn); those apps stay on notifications.
- To update, download the next release. The Update button in the Agents tab is for builds from a git checkout.

</details>

EOF

if [ -n "$CHANGES" ] && [ -s "$CHANGES" ]; then
  COUNT="$(grep -c '^\* ' "$CHANGES" || true)"
  if [ "${COUNT:-0}" -gt 0 ]; then SUMMARY="What's new: $COUNT changes"; else SUMMARY="What's new"; fi
  echo "## What's new"
  echo
  echo "<details>"
  echo "<summary><b>$SUMMARY</b></summary>"
  echo
  # GitHub's own headings ("## What's Changed") sit one level under ours.
  sed 's/^## /### /' "$CHANGES"
  echo
  echo "</details>"
fi
