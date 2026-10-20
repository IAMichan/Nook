# Updating Nook from `main`

Nook is built from its own git checkout, so "a new version" means a pull request that was merged into `main` after the
build you are running. Nook notices that by itself and shows an **Update** button in the panel footer, next to
Settings, on every tab. Installing is always your click.

## How Nook knows which build it is

- `apps/macos/project.yml` writes `NookSourceRoot` (`$(SRCROOT)`), `NookBuildConfiguration` and `NookDeveloperDir` into
  `Info.plist`.
- The **Stamp source commit** build phase (`apps/macos/Config/stamp-source.sh`) adds `NookSourceCommit` and
  `NookSourceBranch` from `git rev-parse HEAD` after `Info.plist` is processed and before Xcode signs the app. It reads
  the checkout, so the Nook target sets `ENABLE_USER_SCRIPT_SANDBOXING: NO` (it is the target's only script phase).
- A build without these keys (not made from a checkout) never shows the button; Settings › Overview › Updates says why.

## Checking

`AppUpdater` (`apps/macos/Services/Updates/AppUpdater.swift`) checks 20 seconds after launch, every 30 minutes, after
the Mac wakes, and when the panel footer appears and the last check is over 10 minutes old. A check runs
`git fetch --no-tags origin main` in the checkout (the default branch comes from `origin/HEAD`) and counts the
first-parent commits between the build's commit and `origin/main`. Merge commits and squash merges are read as pull
requests (number and title) for the list in the panel. A failed check (offline, no remote) stays quiet and is only
shown in Settings. Automatic checks can be turned off in Settings › Overview › Updates; "Check now" always works.

## The button

| State | Footer | Panel |
| --- | --- | --- |
| Update available | Mint **Update** with the number of changes (pulses until you open it) | Merged pull requests (each opens on GitHub), commit range with a compare link, warnings, **Install and restart** |
| Installing | Spinner **Updating…** | The six steps with the current one, what xcodebuild is compiling, elapsed time, **Cancel** |
| Ready to restart | **Restart** | Shown when sessions Nook runs are still working; **Restart now** |
| Failed | Coral **Update failed** | Where it stopped, why, the compiler errors, **Show log**, **Copy errors**, **Try again** |
| Just updated | Mint check | What came in with the update (until you close it) |

The menu bar menu shows the same state as one line that opens the panel.

## Installing

1. **Fetch** `origin/main` again and re-read the checkout.
2. **Update the checkout** with `git merge --ff-only origin/main`. Nook refuses (and says why) when the checkout is on
   another branch, detached, or has local commits on `main`. Uncommitted changes are only set aside with
   `git stash push --include-untracked` when you tick the box, and put back with `git stash pop` afterwards; if they do
   not fit, they stay in the named stash and Nook tells you.
3. **Generate the Xcode project** with `xcodegen generate` in `apps/macos` (found on `PATH`, in Homebrew/Mint folders or
   via your login shell). The iOS project is left alone, so its signing team stays as `./update.sh` set it.
4. **Build** with `xcodebuild -scheme Nook` in the same configuration and with the same Xcode (`DEVELOPER_DIR`) as the
   running build, into Xcode's usual DerivedData, so the build is incremental. Environment variables Xcode injects into a
   debugged app (`DYLD_*` and friends) are removed first.
5. **Install**: when Nook runs from that DerivedData folder, the build already replaced it (the linker and codesign write
   new files, so the running process is unaffected). A copy elsewhere, such as `/Applications`, is swapped: the new app
   is copied next to it with `ditto`, the old one moved aside, the new one moved in, and the old one put back if that
   fails.
6. **Restart**: a small `/bin/sh` loop waits for Nook to quit and opens the app again. If sessions that Nook runs are
   still working, Nook waits for you to press **Restart** (they stop on restart and can be resumed afterwards).

Every step's output goes to `~/Library/Logs/Nook/Update-<date>.log`. The start and the outcome of every install are
written to the action log (`audit` table, tool `app_update`). Cancelling stops the running command; what already
happened stays (a fast-forwarded checkout simply means the next install only builds).
