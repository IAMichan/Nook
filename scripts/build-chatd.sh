#!/bin/bash
# Builds nook-chatd, Nook's own chat helper (apps/chatd, AGPL-3.0), once per Mac: it links Signal, Messenger, Instagram,
# X and LinkedIn without Beeper (see docs/ADR-CHAT-LINKS.md).
#
#   scripts/build-chatd.sh
#
# The result is apps/macos/Vendor/ChatHelper/nook-chatd (not tracked in git). Every Nook build then copies it into
# Nook.app/Contents/Helpers and signs it with Nook's own identity (Config/embed-chatd.sh). Without it Nook builds as
# before and those apps stay on notifications.
#
# Signal needs libsignal's Rust library, built here at exactly the commit the Signal connector in apps/chatd/go.mod
# pins. Needs Homebrew's go and protoc, and Rust (rustup). Takes 5–15 minutes the first time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/chatd"
OUT="$ROOT/apps/macos/Vendor/ChatHelper"
WORK="${CHATD_WORK:-$ROOT/.build/chatd}"

for tool in go cargo git protoc; do
  command -v "$tool" >/dev/null || { echo "✗ $tool is missing: brew install go protobuf, and rustup for cargo"; exit 1; }
done
mkdir -p "$WORK" "$OUT"

# 1. Which libsignal: the submodule commit of the mautrix-signal version that go.mod uses.
SIGNAL_VERSION="$(cd "$SRC" && go list -m -f '{{.Version}}' go.mau.fi/mautrix-signal)"
if [ ! -d "$WORK/signal-$SIGNAL_VERSION/.git" ]; then
  rm -rf "$WORK"/signal-*
  git clone --quiet --depth 1 --branch "$SIGNAL_VERSION" https://github.com/mautrix/signal.git "$WORK/signal-$SIGNAL_VERSION"
fi
LIBSIGNAL_REF="$(git -C "$WORK/signal-$SIGNAL_VERSION" ls-tree HEAD pkg/libsignalgo/libsignal | awk '{print $3}')"
[ -n "$LIBSIGNAL_REF" ] || { echo "✗ Could not read libsignal's commit from mautrix-signal $SIGNAL_VERSION"; exit 1; }

# 2. libsignal_ffi.a at that commit (static, so the helper depends on nothing outside macOS).
if [ ! -d "$WORK/libsignal/.git" ]; then
  git clone --quiet https://github.com/signalapp/libsignal.git "$WORK/libsignal"
fi
if [ "$(git -C "$WORK/libsignal" rev-parse HEAD)" != "$LIBSIGNAL_REF" ] || [ ! -f "$WORK/libsignal/target/release/libsignal_ffi.a" ]; then
  git -C "$WORK/libsignal" fetch --quiet origin "$LIBSIGNAL_REF"
  git -C "$WORK/libsignal" checkout --quiet "$LIBSIGNAL_REF"
  echo "Building libsignal $LIBSIGNAL_REF for mautrix-signal $SIGNAL_VERSION"
  (cd "$WORK/libsignal" && MACOSX_DEPLOYMENT_TARGET=15.0 RUSTFLAGS="-Ctarget-feature=-crt-static" RUSTC_WRAPPER="" \
    cargo build -p libsignal-ffi --profile=release)
fi

# 3. The helper itself.
VERSION="$(git -C "$ROOT" rev-parse --short HEAD)"
echo "Building nook-chatd $VERSION"
(cd "$SRC" && MACOSX_DEPLOYMENT_TARGET=15.0 CGO_ENABLED=1 CGO_LDFLAGS="-L$WORK/libsignal/target/release" \
  go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$OUT/nook-chatd" .)

# Only macOS's own libraries: anything from Homebrew would be missing on another Mac.
if otool -L "$OUT/nook-chatd" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/'; then
  echo "✗ nook-chatd links to the libraries above, outside macOS."
  rm -f "$OUT/nook-chatd"
  exit 1
fi
echo "$VERSION libsignal=$LIBSIGNAL_REF" > "$OUT/VERSION"
echo "✓ $OUT/nook-chatd. Build Nook again to include it."
