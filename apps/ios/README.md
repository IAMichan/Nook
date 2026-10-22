# Nook for iOS (`NookCompanion`)

This directory contains **Nook Companion**, the iPhone app that shows which coding-agent sessions on your Mac need your attention, with support for approving or denying tool calls, answering questions, sending follow-up messages, and stopping sessions. It is Nook made for iPhone: a Today home, agent sessions you can start and follow, chats with Nook, and your usage and plan limits. It communicates directly with Nook on your Mac over your local Wi-Fi network; see [`docs/COMPANION.md`](../../docs/COMPANION.md).

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
  Theme.swift            the one design: colors, radii, spacing, cards, buttons, status pills, agent icons
  CompanionViews.swift   root tabs, pairing, session overview
  SessionViews.swift     a session as a conversation, starting a new session
  ChatViews.swift        Nook's own chats, shared bubble and composer
  HomeViews.swift        Today: greeting, what needs you, For you, agenda, now playing, limits, starters
  UsageViews.swift       plan limits, tokens and costs, tokens per day, usage per model
```

The wire protocol, ChaCha20-Poly1305 sealing, and SHA-256/HMAC helpers are shared with the macOS app via [`packages/protocol`](../../packages/protocol).
