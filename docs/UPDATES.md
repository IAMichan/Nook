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
- A build without these keys and without a release stamp (below) never shows the button; Settings › Overview › Updates
  says why.

## Checking

`AppUpdater` (`apps/macos/Services/Updates/AppUpdater.swift`) checks 20 seconds after launch, every 30 minutes, after
the Mac wakes, and when the panel footer appears and the last check is over 10 minutes old (not in the first 20 seconds
after launch: the main window opens with Nook, and the launch check follows right after). A check runs
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
   fails. The old one is kept for a rollback (below).
6. **Restart**: a small `/bin/sh` loop waits for Nook to quit and opens the app again. If sessions that Nook runs are
   still working, Nook waits for you to press **Restart** (they stop on restart and can be resumed afterwards).
   The new build opens the main window on the screen you clicked **Install** (or **Restart**) on: the main window's
   screen when it had the keyboard, else the screen under the pointer (the notch's panel).

Every step's output goes to `~/Library/Logs/Nook/Update-<date>.log`. The start and the outcome of every install are
written to the action log (`audit` table, tool `app_update`). Cancelling stops the running command; what already
happened stays (a fast-forwarded checkout simply means the next install only builds).

## Rollback when the new build does not start

An update that swapped the app (step 5, or a release install) keeps the previous app in
`~/Library/Application Support/Nook/Rollback/Nook.app` instead of deleting it, and puts the new build **on trial**
(`UpdateTrial.swift`, `UpdateTrialRunner.swift`; the record is `update-trial.json` next to it):

1. The relaunch script waits until the old process is gone, then copies `nook.sqlite` with its `-wal` and `-shm` to
   `Rollback/database`, so the snapshot is consistent and taken before the new build can migrate anything.
2. The new build marks each launch as running before anything opens the database (`main.swift`). After a minute of
   normal running it commits: the kept app and the snapshot are removed. A normal quit before that does not count.
3. If a launch of the new build ended in a crash before it committed, the next launch restores: the database snapshot
   goes back first, then the previous app replaces the new one, the previous app starts, and the new process exits. A
   restore that was interrupted is finished by whichever build starts next.
4. The previous build then shows **Update failed** in the footer with what happened, and writes `rolled back` to the
   action log (`app_update`).

A build that runs in place from Xcode's DerivedData keeps no previous app, so it has no trial. A build that crashes
before `main.swift` runs (a missing library) cannot roll itself back; download the previous release by hand then.
Sessions Nook runs are not resumed automatically after an update restart (they can be resumed by hand, as before).

## Release builds (the .dmg and .zip)

A build downloaded from [GitHub Releases](https://github.com/IAMichan/nook/releases) has no checkout to rebuild. The
release workflow (`.github/workflows/release.yml`) removes the source stamp and writes `NookReleaseVersion` (the full
version, `0.3.0-beta.2`) and `NookReleaseRepository` (`owner/name`) into its `Info.plist` instead, plus the public key
`NookUpdatePublicKey` from the repository variable `NOOK_UPDATE_PUBLIC_KEY`. Such a build updates itself from the
releases, behind the same footer button (`ReleaseUpdateCore.swift`, `AppUpdater`):

- **Checking** asks `api.github.com/repos/<repository>/releases` on the same schedule as above. A beta build is offered
  newer betas and releases, a regular release only regular releases; drafts never. Versions compare like SemVer
  (`0.3.0-beta.2` < `0.3.0-beta.10` < `0.3.0`).
- **Installing** shows four steps: **download** `Nook-<version>-macOS.zip` and `Nook-<version>-macOS.zip.sig` from
  GitHub; **verify** the Ed25519 signature of the .zip against the public key in this build (CryptoKit), unpack it with
  `ditto`, and refuse an app that is not `nl.imdigital.nook` or whose `NookReleaseVersion` is not the promised version
  (so an older signed .zip renamed as a newer release cannot downgrade you), then `codesign --verify` it; **install**
  swaps the app in place exactly as step 5 above; **restart** as step 6.
- A newer release **without a signature**, or a build **without a public key**, is never installed: Settings shows the
  release with a **Download** link instead.

### Setting up the signing key (once, for maintainers)

1. On a Mac, run `swift scripts/sign-update.swift generate`. It prints a private and a public key (base64 of the raw
   32-byte Ed25519 keys).
2. Add the private key as the repository **secret** `NOOK_UPDATE_SIGNING_KEY` (Settings › Secrets and variables ›
   Actions › Secrets). Keep a copy somewhere safe: losing it means builds already out there can no longer take updates.
3. Add the public key as the repository **variable** `NOOK_UPDATE_PUBLIC_KEY` (same page, *Variables*). It is built
   into every release from then on.

The workflow signs the .zip after notarization (`Sign the update`) and uploads the `.zip.sig`; the script refuses a
private key that does not belong to `NOOK_UPDATE_PUBLIC_KEY`. With either one missing, the step prints a warning and
the release goes out without a signature, as before. Builds released before the key existed carry no public key, so
they need one manual download to start updating themselves. Rotating the key works the same way: builds with the old
key then also need one manual download.
