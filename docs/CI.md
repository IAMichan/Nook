# CI

Nook's CI runs on GitHub Actions. The macOS runners are the scarce resource: the repository gets only a handful at a
time, and every queued macOS job makes the next pull request wait. The workflows are built to start one only when it
can tell us something new.

| Workflow | Runs on | When |
|---|---|---|
| `build.yml` | ubuntu (UI lint), then macOS (build + `NookTests`) | `apps/macos`, `packages/protocol`, `scripts/ui-lint.sh` |
| `ios.yml` | ubuntu (gate), then macOS (Companion build) | `apps/ios`, `packages/protocol` |
| `packages.yml` | ubuntu, then macOS (`swift test` of `packages/core`) | `packages/core` |
| `tauri.yml` | ubuntu + Windows checks; installers and APK only on `main` | `apps/tauri` |
| `cancel-stale-runs.yml` | ubuntu, by hand | cancels runs of pull requests that are already closed |

A workflow also runs when its own file changes (and `.github/actions/**` for the ones that use it).

## What keeps the minutes down

- **Path filters.** A pull request that only touches docs starts no runner at all; one that only touches the Tauri app
  starts no macOS runner.
- **One run per pull request.** A new push, or merging or closing the PR, cancels the run that is still going. On `main`
  a running build finishes and only the newest push waits behind it, so a burst of merges costs at most two builds.
- **Drafts wait.** Draft pull requests run nothing; marking one ready for review starts CI.
- **Cheap checks first.** The macOS build starts only after the UI lint passed; the macOS leg of `packages.yml` only
  after Linux passed; Windows and the packaging jobs only after the Linux checks passed.
- **No second build of the same inputs.** `verified-check` (in `.github/actions`) hashes the git trees a macOS job builds
  from. When a run of this repository already passed on exactly that hash, the macOS job is skipped and the summary
  links that run. This catches the push to `main` after merging a pull request that was green on an up-to-date base,
  and a pull request that merged in unrelated changes from `main`. `verified-mark` uploads the small marker artifact
  (kept 30 days) at the end of a passing job. Markers from forks never count, and *Run workflow* always builds.
- **Caches.** `build.yml` caches the Swift packages' checkouts and build products (MLX, FluidAudio, llama.cpp, …) per
  Xcode build and `project.yml`; Nook's own sources always rebuild. The Tauri jobs cache Rust with `rust-cache` and npm
  with `setup-node`. Only `main` saves caches, so pull requests cannot push each other's entries out of the quota.
- **One compile for build and tests.** `xcodebuild build-for-testing` builds the app and `NookTests` once;
  `test-without-building` runs the tests.
- **Packaging on `main` only.** The Windows and Linux installers and the Android APK (64-bit ARM only) are built on
  `main` and by hand, where they are worth downloading. Pull requests run Clippy and the tests on Linux and Windows.

## What keeps it reliable

- **Pinned versions.** Every action is pinned to a commit SHA (Dependabot proposes updates, grouped into one pull
  request a month). The Rust version lives in `apps/tauri/rust-toolchain.toml`, so a new stable release with new Clippy
  lints cannot turn `main` red on its own; bump it on purpose, together with the fixes Clippy asks for.
- **Retries where the network is involved.** Swift package resolution retries three times; `apt-get` retries downloads.
- **Timeouts** on every job, and tighter ones on the macOS build and test steps, so a hung step is released quickly.
- **No signing in CI.** The macOS build runs with `CODE_SIGNING_ALLOWED=NO`; `Config/local-signing.sh` creates no local
  identity when `CI` is set, and `Config/resign-local.sh` does not re-sign an unsigned build. Otherwise `codesign` waits
  for a keychain password prompt that never comes.
- **Logs of a failed macOS build** (`build.log`, `test.log`, and the `.xcresult` bundle) are uploaded as an artifact for
  seven days.

## Adding a workflow

Copy the `on:` block (with `closed` in the pull request types), the `concurrency` block, and the `if:` on the first job
from `build.yml`. For a job on a macOS runner, put `verified-check` in a cheap ubuntu job before it (with the same paths
as the filter) and `verified-mark` as the last step of the macOS job.
