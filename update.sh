#!/bin/sh
# Fetches the latest code and regenerates the Xcode project to include any new files.
# Usage:  ./update.sh
set -e
cd "$(dirname "$0")"
git pull
xcodegen
echo "Done. Open Nook.xcodeproj and press ⌘R."
