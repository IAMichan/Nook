#!/bin/sh
# Haalt de nieuwste code op en maakt het Xcode-project opnieuw, zodat nieuwe bestanden erin zitten.
# Gebruik:  ./update.sh
set -e
cd "$(dirname "$0")"
git pull
xcodegen
echo "Klaar. Open Nook.xcodeproj en druk op ⌘R."
