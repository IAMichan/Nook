# Changelog

Notable changes to Nook, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org) with `-beta.N` pre-releases.

Every [GitHub release](https://github.com/IAMichan/nook/releases) also lists each merged pull request, grouped by label
(see `.github/release.yml`). This file is the short, human-written summary: when your pull request changes something a
user or contributor notices, add a line under **Unreleased**. At release time that section becomes the new version.

## Unreleased

### Added

- A short demo video at the top of the README (`docs/assets/nook-demo.mp4`, with a GIF preview), made with the
  `nook-video` skill, which can now render landscape clips (`--size`).
- Area labels (`area: macos`, `area: tauri`, …) that are added to pull requests automatically, defined in
  `.github/labels.yml`.
- Release notes grouped by label, and this changelog.
- Dependabot updates for the Tauri app (Cargo and npm) and `nook-chatd` (Go modules).
- `CODEOWNERS`, `.editorconfig`, and `.gitattributes`.
- A *Related issues* section in the pull request template.
- Agent transcripts read more like Code's: the thought behind the running step shows above it, a message sent while
  the agent worked splits its turn's fold ("Continued for 20s"), a stopped turn stays open ("You stopped after 12s"),
  compactions, API errors and usage limits stay in sight, and a command opens to its output.
- iPhone companion: repeated commands are carried out once (an LRU receipt store), protocol and app versions with
  "Update Nook on your Mac" / "Update the app" banners, "Why can't I connect?" on the phone and *Test relay* on the Mac,
  per-phone scopes chosen at pairing, one phone paired with several Macs, a local redacted *Copy diagnostics* log, and
  shared golden protocol fixtures checked from Swift, Rust and the relay.

### Fixed

- The pull request list loads much faster and no longer looks like it is always loading: the quick refresh reads only
  the open pull requests, the closed ones and watched organizations follow in the background every few minutes, and
  only a refresh you ask for shows a spinner.
- "Post this on LinkedIn" and other requests to post on a site that don't start with a known verb are taken over
  again instead of being answered with text.

### Changed

- A pull request opens beside the list opens one: half the page, its edge dragged wider or
  narrower (remembered), and a button on its tab line that makes it fill the page.
- A pull request's page looks: a one-line title, segmented tabs, its tabs as `#number` whose mark turns
  into a close button, refreshing in the ⋯ menu, and a timeline with each commit as its own entry.
- A pull request's Summary opens with whether it can merge: conflicts, checks, reviews and a branch behind, one line
  each with its state's color, and a click on a line goes to what needs you. Failing checks are listed first.
- `docs/WERKRUIMTE-AGENTS.md` is now `docs/WORKSPACE-AGENTS.md`.

## [0.1.0-beta.1] - 2026-10-23

First public beta of the macOS app, published from `.github/workflows/release.yml`.

[0.1.0-beta.1]: https://github.com/IAMichan/nook/releases/tag/v0.1.0-beta.1
