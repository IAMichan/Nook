# Changelog

Notable changes to Nook, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org) with `-beta.N` pre-releases.

Every [GitHub release](https://github.com/IAMichan/nook/releases) also lists each merged pull request, grouped by label
(see `.github/release.yml`). This file is the short, human-written summary: when your pull request changes something a
user or contributor notices, add a line under **Unreleased**. At release time that section becomes the new version.

## Unreleased

### Added

- Area labels (`area: macos`, `area: tauri`, …) that are added to pull requests automatically, defined in
  `.github/labels.yml`.
- Release notes grouped by label, and this changelog.
- Dependabot updates for the Tauri app (Cargo and npm) and `nook-chatd` (Go modules).
- `CODEOWNERS`, `.editorconfig`, and `.gitattributes`.
- A *Related issues* section in the pull request template.

### Changed

- `docs/WERKRUIMTE-AGENTS.md` is now `docs/WORKSPACE-AGENTS.md`.

## [0.1.0-beta.1] - 2026-10-23

First public beta of the macOS app, published from `.github/workflows/release.yml`.

[0.1.0-beta.1]: https://github.com/IAMichan/nook/releases/tag/v0.1.0-beta.1
