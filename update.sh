#!/bin/sh
# Fetches the latest code and regenerates the Xcode projects of the Apple apps (apps/macos, apps/ios).
# Usage:  ./update.sh
set -e
cd "$(dirname "$0")"
git pull
(cd apps/macos && xcodegen)
(cd apps/ios && xcodegen)

# The macOS app gets its signing team from apps/macos/Config/local-signing.sh (run by xcodegen). The iOS companion still
# takes the local Apple Development team from Keychain (if available) here, without storing a Team ID in git.
TEAM_ID="${DEVELOPMENT_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1)}"
if [ -n "$TEAM_ID" ]; then
  for pbx in apps/ios/NookCompanion.xcodeproj/project.pbxproj; do
    if [ -f "$pbx" ]; then
      sed -i '' -e "s/DEVELOPMENT_TEAM = \"\";/DEVELOPMENT_TEAM = $TEAM_ID;/g" -e '/CODE_SIGN_IDENTITY = "-";/d' "$pbx"
    fi
  done
fi

if [ -d Nook.xcodeproj ]; then
  echo "Let op: ./Nook.xcodeproj is van vóór de monorepo en verwijst naar oude paden. Verwijder hem: rm -rf Nook.xcodeproj"
fi
echo "Klaar. Open apps/macos/Nook.xcodeproj (of apps/ios/NookCompanion.xcodeproj) en druk op ⌘R."
