#!/bin/bash
# Builds TDLib, Telegram's own client library, for Nook's Telegram bridge (Chats tab), once per Mac.
#
#   scripts/build-tdlib.sh            build TDLIB_REF (default: master) for this Mac's architecture
#   TDLIB_REF=<commit> scripts/build-tdlib.sh
#
# The result is apps/macos/Vendor/TDLib/libtdjson.dylib (not tracked in git). Every Nook build then copies it into
# Nook.app/Contents/Frameworks and signs it with Nook's own identity (Config/embed-tdlib.sh), so Nook loads it with the
# hardened runtime and library validation left on. Without it Nook builds as before and Telegram stays on notifications.
#
# Needs Xcode's command line tools and Homebrew's cmake, gperf and openssl@3. OpenSSL is linked statically, so the
# library depends on nothing outside macOS itself (checked at the end). Takes 15–30 minutes the first time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/apps/macos/Vendor/TDLib"
WORK="${TDLIB_WORK:-$ROOT/.build/tdlib}"
REF="${TDLIB_REF:-master}"

for tool in cmake gperf git; do
  command -v "$tool" >/dev/null || { echo "✗ $tool is missing: brew install cmake gperf"; exit 1; }
done
OPENSSL="$(brew --prefix openssl@3 2>/dev/null || true)"
[ -n "$OPENSSL" ] && [ -f "$OPENSSL/lib/libssl.a" ] || { echo "✗ OpenSSL is missing: brew install openssl@3"; exit 1; }

mkdir -p "$WORK"
if [ ! -d "$WORK/td/.git" ]; then
  git clone https://github.com/tdlib/td.git "$WORK/td"
fi
git -C "$WORK/td" fetch --quiet origin
git -C "$WORK/td" checkout --quiet "$REF"
[ "$REF" = "master" ] && git -C "$WORK/td" reset --quiet --hard origin/master
COMMIT="$(git -C "$WORK/td" rev-parse HEAD)"
echo "Building TDLib $COMMIT"

cmake -S "$WORK/td" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DOPENSSL_ROOT_DIR="$OPENSSL" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DTD_ENABLE_JNI=OFF
cmake --build "$WORK/build" --target tdjson -j "$(sysctl -n hw.ncpu)"

LIB="$(find "$WORK/build" -maxdepth 1 -name 'libtdjson*.dylib' -type f | head -1)"
[ -n "$LIB" ] || { echo "✗ The build made no libtdjson.dylib"; exit 1; }
mkdir -p "$OUT"
cp "$LIB" "$OUT/libtdjson.dylib"
install_name_tool -id @rpath/libtdjson.dylib "$OUT/libtdjson.dylib"

# Library validation only lets Nook load code signed like itself (or by Apple): the library may not pull in Homebrew's.
if otool -L "$OUT/libtdjson.dylib" | tail -n +2 | awk '{print $1}' | grep -v -e '^@rpath/libtdjson' -e '^/usr/lib/' -e '^/System/'; then
  echo "✗ libtdjson.dylib links to the libraries above, outside macOS: Nook could not load it."
  rm -f "$OUT/libtdjson.dylib"
  exit 1
fi
echo "$COMMIT" > "$OUT/VERSION"
echo "✓ $OUT/libtdjson.dylib (TDLib $COMMIT). Build Nook again to include it."
