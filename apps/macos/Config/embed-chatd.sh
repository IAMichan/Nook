#!/bin/sh
# Build phase of the Nook target (project.yml): copies nook-chatd, Nook's chat helper, when scripts/build-chatd.sh built
# it, into Nook.app/Contents/Helpers and signs it with the identity Xcode signs Nook with and the hardened runtime. Nook
# runs it as a child process for Signal, Messenger, Instagram, X and LinkedIn. Without it there is nothing to do: Nook
# builds as before and those apps stay on notifications. Never fails the build.
HELPER="$SRCROOT/Vendor/ChatHelper/nook-chatd"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
if [ ! -f "$HELPER" ]; then
  rm -f "$DEST/nook-chatd"
  exit 0
fi
mkdir -p "$DEST"
cp -f "$HELPER" "$DEST/nook-chatd"
if [ "$CODE_SIGNING_ALLOWED" != "NO" ] && [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$DEST/nook-chatd" \
    || echo "warning: could not sign nook-chatd; Signal, Messenger, Instagram, X and LinkedIn will not link"
fi
exit 0
