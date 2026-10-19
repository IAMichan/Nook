#!/bin/sh
# Fetches the latest code and regenerates the Xcode projects of the Apple apps (apps/macos, apps/ios).
# Usage:  ./update.sh
set -e
cd "$(dirname "$0")"
git pull
(cd apps/macos && xcodegen)
(cd apps/ios && xcodegen)
if [ -d Nook.xcodeproj ]; then
  echo "Let op: ./Nook.xcodeproj is van vóór de monorepo en verwijst naar oude paden. Verwijder hem: rm -rf Nook.xcodeproj"
fi
echo "Klaar. Open apps/macos/Nook.xcodeproj (of apps/ios/NookCompanion.xcodeproj) en druk op ⌘R."
