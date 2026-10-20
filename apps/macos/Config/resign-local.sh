#!/bin/sh
# Post-build action of the Nook scheme (project.yml). When Config/local-signing.sh found no Apple Development certificate,
# Xcode signs Nook ad hoc, and an ad-hoc signature changes with every build: macOS then treats each build as a new app and
# asks for Keychain access and privacy permissions again. This re-signs the built app with the stable local identity
# (NOOK_LOCAL_SIGNING_IDENTITY), keeping the entitlements and hardened runtime Xcode signed it with.
# Output goes to local-signing.log next to the app. Never fails the build.
[ -n "$NOOK_LOCAL_SIGNING_IDENTITY" ] || exit 0
# A build that is not signed at all (CI passes CODE_SIGNING_ALLOWED=NO) is not re-signed either.
[ "$CODE_SIGNING_ALLOWED" = "NO" ] && exit 0
APP="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
[ -d "$APP" ] || exit 0
LOG="$TARGET_BUILD_DIR/local-signing.log"

# Already signed with the identity (an incremental build that did not re-sign): nothing to do.
if codesign -dvv "$APP" 2>&1 | grep -q "^Authority=Nook Local Signing$" && codesign --verify "$APP" >/dev/null 2>&1; then
  exit 0
fi

{
  echo "== $(date)"
  # Nested code first (-depth lists children before their parents), then the app itself.
  find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
    -print 2>/dev/null | while IFS= read -r ITEM; do
    codesign --force --sign "$NOOK_LOCAL_SIGNING_IDENTITY" --preserve-metadata=entitlements,flags --timestamp=none "$ITEM"
  done
  codesign --force --sign "$NOOK_LOCAL_SIGNING_IDENTITY" --preserve-metadata=entitlements,flags --timestamp=none "$APP" \
    && echo "Signed $APP with $NOOK_LOCAL_SIGNING_IDENTITY"
} >> "$LOG" 2>&1
exit 0
