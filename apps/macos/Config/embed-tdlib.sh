#!/bin/sh
# Build phase of the Nook target (project.yml): copies TDLib, when scripts/build-tdlib.sh built it, into
# Nook.app/Contents/Frameworks and signs it with the identity Xcode signs Nook with. Library validation then lets Nook
# load it for the Telegram bridge. Without it there is nothing to do: Nook builds as before. Never fails the build.
LIB="$SRCROOT/Vendor/TDLib/libtdjson.dylib"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
if [ ! -f "$LIB" ]; then
  rm -f "$DEST/libtdjson.dylib"
  exit 0
fi
mkdir -p "$DEST"
cp -f "$LIB" "$DEST/libtdjson.dylib"
if [ "$CODE_SIGNING_ALLOWED" != "NO" ] && [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$DEST/libtdjson.dylib" \
    || echo "warning: could not sign libtdjson.dylib; Telegram will not load"
fi
exit 0
