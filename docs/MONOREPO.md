# Monorepo Structure

Nook is organized as a single multi-platform repository. Today, the native macOS app and the iPhone companion app are implemented; additional platform directories are scaffolded with their architecture guidelines, and shared logic is tested in CI.

```text
apps/
  macos/     Native macOS app (Swift, AppKit/SwiftUI, XcodeGen) — built and tested in CI
  ios/       Nook Companion for iPhone (SwiftUI, XcodeGen) — companion app & foundation for Nook on iOS
  android/   Planned Android app scaffold
  windows/   Planned Windows app scaffold
  linux/     Planned Linux app scaffold
packages/
  core/      Platform-independent Swift core package (Foundation-only)
  protocol/  Shared Companion protocol, ChaCha20-Poly1305 sealing, and HMAC/SHA-256 verification (used by macOS and iOS)
docs/        Architecture and subsystem documentation
scripts/     Helper scripts (including core-tests.sh and local model fine-tuning)
```

## Architectural Rules

- Every app lives in `apps/<platform>` with its own build configuration, project file, and tests. CI workflows use path filters so each platform job runs only when files in its directory (or a shared package it depends on) change.
- Logic shared across more than one platform belongs in `packages/`, never duplicated across app targets. A package must never depend on an app target.
- Shared packages rely strictly on `Foundation` (no `AppKit`, `UIKit`, or `Combine`) so they compile cleanly on macOS, iOS, Linux, Windows, and Android. The only platform-conditional file is `CompanionSeal.swift` in `packages/protocol` (which uses `CryptoKit` on Apple platforms).
- Platform-specific capabilities (notch UI, menu bar, AppleScript, `ScreenCaptureKit`, Keychain) remain in the platform app behind clean protocols.

## Current State

- **macOS App (`apps/macos`):** Generated via XcodeGen (`cd apps/macos && xcodegen`).
- **iPhone Companion (`apps/ios`):** Generated via XcodeGen (`cd apps/ios && xcodegen`). Shares `packages/protocol` with the macOS app; see [`docs/COMPANION.md`](COMPANION.md).
- **Portable Core (`packages/core` & `scripts/core-tests.sh`):** Over 850 unit tests in `apps/macos/Tests/NookTests` are already pure `Foundation` and run via `./scripts/core-tests.sh` (`swift test`). As additional desktop/mobile platforms are implemented, those Foundation-only modules move into `packages/core`.

## Adding a New Platform

1. Move the required Foundation-only modules into `packages/core` and link `apps/macos` against it via Swift Package Manager.
2. Set up the native UI project in `apps/<platform>` (see the `README.md` in each platform folder).
3. Implement platform adapters for storage, secrets, screen reading, calendar, and global shortcuts.
4. Add a dedicated CI workflow in `.github/workflows/` with `paths:` filters for `apps/<platform>/**` and `packages/**`.
5. Document any new dependencies in `README.md` and `THIRD-PARTY-NOTICES.md`.
