#!/bin/sh
# Build phase of the Nook target (project.yml): writes the git commit and branch this build was made from into the built
# app's Info.plist (NookSourceCommit, NookSourceBranch). Nook compares that commit with the repository's main branch to
# offer an update in the Agents footer when a pull request was merged since (see Services/Updates).
#
# Runs after Info.plist is processed and before Xcode signs the app, so the signature covers the stamped values.
# Outside a git checkout (or without git) it leaves the plist alone: Nook then simply offers no updates. Never fails the build.
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[ -f "$PLIST" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

COMMIT="$(git -C "$SRCROOT" rev-parse --verify --quiet HEAD 2>/dev/null)"
[ -n "$COMMIT" ] || exit 0
BRANCH="$(git -C "$SRCROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)"

# Rewriting an unchanged plist would make Xcode sign the app again on every build: only write what changed.
stamp() {
  [ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null)" = "$2" ] && return 0
  plutil -replace "$1" -string "$2" "$PLIST" 2>/dev/null
}
stamp NookSourceCommit "$COMMIT"
stamp NookSourceBranch "$BRANCH"
exit 0
