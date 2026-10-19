# Nook for iOS (`NookCompanion`)

This directory contains **Nook Companion**, the iPhone app that shows which coding-agent sessions on your Mac need your attention, with support for approving or denying tool calls, answering questions, sending follow-up messages, and stopping sessions. It communicates directly with Nook on your Mac over your local Wi-Fi network; see [`docs/COMPANION.md`](../../docs/COMPANION.md).

## Building

```sh
brew install xcodegen
cd apps/ios
xcodegen
open NookCompanion.xcodeproj
```

Select an iPhone simulator (or configure your own Apple Developer Team in Xcode for a physical device) and press `⌘R`. `NookCompanion.xcodeproj`, `Info.plist`, and the `.entitlements` file are generated from [`project.yml`](project.yml) and are ignored by Git.

## Structure

```text
NookCompanion/   SwiftUI app: QR pairing, session list, inline actions, APNs push notifications
```

The wire protocol, ChaCha20-Poly1305 sealing, and SHA-256/HMAC helpers are shared with the macOS app via [`packages/protocol`](../../packages/protocol).
