#!/bin/bash
# Writes the release page (.github/workflows/release.yml) to stdout: the banner, the Mac, Windows and Linux download
# buttons with the other downloads right under them, the three install steps, and the change list folded away at the bottom, so
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

# The Windows and Linux files come from tauri.yml and are attached by the `desktop` job after this page is written; the
# release stays a draft until they are there, so the links below work once it is public. Their names are set there.
EXE="Nook-$VERSION-Windows-setup.exe"
MSI="Nook-$VERSION-Windows.msi"
APPIMAGE="Nook-$VERSION-Linux.AppImage"
DEB="Nook-$VERSION-Linux.deb"

# A button: a shields.io badge in Nook's paper white on its near-black ink, with the platform's mark.
badge() { # label, file type, logo
  echo "https://img.shields.io/badge/$1-$2-F5F5F5?style=for-the-badge&logo=$3&logoColor=0B0B0D&labelColor=F5F5F5&color=D6D6D6"
}
# Simple Icons (shields.io's logos) has no Microsoft mark, so the four squares go along as an SVG in Microsoft's colors.
MICROSOFT_SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 23 23"><path fill="#F25022" d="M1 1h10v10H1z"/><path fill="#7FBA00" d="M12 1h10v10H12z"/><path fill="#00A4EF" d="M1 12h10v10H1z"/><path fill="#FFB900" d="M12 12h10v10H12z"/></svg>'
MICROSOFT_LOGO="data:image/svg%2bxml;base64,$(printf '%s' "$MICROSOFT_SVG" | base64 | tr -d '\n')"
MAC_BUTTON="$(badge Mac ".dmg$(size_of "$DMG" | sed 's/ · /_%C2%B7_/; s/ /_/g')" apple)"
WINDOWS_BUTTON="$(badge Windows .exe "$MICROSOFT_LOGO")"
LINUX_BUTTON="$(badge Linux .AppImage linux)"

cat <<EOF
<p align="center">
  <img src="$BANNER" alt="Nook: your AI assistant and coding-agent command center, in the notch" width="900">
</p>

<p align="center">
  <a href="$DOWNLOADS/$DMG"><img src="$MAC_BUTTON" alt="Download Nook for Mac (.dmg)" height="40"></a>
  <a href="$DOWNLOADS/$EXE"><img src="$WINDOWS_BUTTON" alt="Download Nook for Windows (.exe)" height="40"></a>
  <a href="$DOWNLOADS/$APPIMAGE"><img src="$LINUX_BUTTON" alt="Download Nook for Linux (.AppImage)" height="40"></a>
</p>

<p align="center">
  <sub><b>Mac:</b> Apple Silicon (M1 or newer) · macOS 15 Sequoia or newer · <a href="$DOWNLOADS/$ZIP">.zip instead</a>$(size_of "$ZIP") · <a href="$DOWNLOADS/SHA256SUMS.txt">SHA-256 checksums</a></sub><br>
  <sub><b>Windows:</b> <a href="$DOWNLOADS/$MSI">.msi instead</a> · <b>Linux:</b> <a href="$DOWNLOADS/$DEB">.deb instead</a> · <a href="$DOWNLOADS/SHA256SUMS-Windows-Linux.txt">SHA-256 checksums</a> · <a href="https://github.com/$REPO/releases">all releases</a></sub>
</p>

EOF

if [ "$PRERELEASE" = "true" ]; then
  cat <<EOF
> [!NOTE]
> This is a beta: expect rough edges, and please report problems in [Issues](https://github.com/$REPO/issues).

EOF
fi

cat <<EOF
## Install on a Mac in three steps

1. **Open** \`$DMG\` and drag **Nook** onto **Applications**.
EOF
if [ "$NOTARIZED" = "true" ]; then
  echo "2. **Open Nook** from Applications. It lives in your notch and the menu bar (no Dock icon)."
else
  cat <<'EOF'
2. **Allow the first launch.** This build is not notarized by Apple yet, so macOS blocks it the first time ("Apple could not verify Nook is free of malware…"). That is expected, and you only do this once:
   1. Open **Nook** from Applications. When macOS warns you, click **Done** (not "Move to Trash").
   2. Open **System Settings › Privacy & Security** and scroll down to the **Security** section.
   3. Next to *"Nook" was blocked to protect your Mac*, click **Open Anyway**.
   4. Confirm with your password or Touch ID, then click **Open Anyway** once more.

   Prefer Terminal? Run this once instead:
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
- Nook shows an **Update** button at the bottom of the panel when a newer signed release is out, and installs it with one click (Nook checks the signature first). Otherwise, download the next release.

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
