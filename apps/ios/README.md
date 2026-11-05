# Nook for iOS (`NookCompanion`)

This directory contains **Nook Companion**, the iPhone app that shows which coding-agent sessions on your Mac need your attention, with support for approving or denying tool calls, answering questions, sending follow-up messages, and stopping sessions. It is Nook's panel made for iPhone, with the Mac's three tabs: Nook (chat with Nook), Agents (sessions you can start and follow) and Chats (your chat apps). It communicates directly with Nook on your Mac over your local Wi-Fi network; see [`docs/COMPANION.md`](../../docs/COMPANION.md).

## Building

```sh
brew install xcodegen
cd apps/ios
xcodegen
open NookCompanion.xcodeproj
```

Select an iPhone simulator (or, for a physical device, put your Apple Developer Team in `Config/Signing.local.xcconfig`: `DEVELOPMENT_TEAM = YOURTEAMID`, see `Config/Signing.xcconfig`) and press `⌘R`. `NookCompanion.xcodeproj`, `Info.plist`, and the `.entitlements` file are generated from [`project.yml`](project.yml) and are ignored by Git.

## Structure

```text
NookCompanion/   SwiftUI app: QR pairing, session list, inline actions, APNs push notifications
  Theme.swift            `Theme` = the Mac's `NookTheme`, plus how a session's state reads and the system bars
  ThemeViews.swift       cards, section headers, status pills and banners, built on the parts shared with the Mac
  PanelComponents.swift  the panel's header and tabs, the search field, the composer and starters
  CompanionViews.swift   root (Nook, Agents, Chats), pairing, session overview
  SessionViews.swift     a session as a conversation, starting a new session
  ChatViews.swift        Nook's own chats, shared bubble and composer
  InboxViews.swift       the Mac's Chats tab: every chat app in one list, a chat as bubbles, answering WhatsApp
  LiveActivities.swift   Live Activity tokens for the Mac, the switch, updates while the app is open
NookActivity/    widget extension: the Live Activity on the Lock Screen and in the Dynamic Island
Shared/          what the app and the extension share (ActivityKit attributes, how a phase looks)
```

The wire protocol, ChaCha20-Poly1305 sealing, and SHA-256/HMAC helpers are shared with the macOS app via [`packages/protocol`](../../packages/protocol).

The design is shared too: the app compiles the Mac's theme (`apps/macos/NotchUI/Theme/NookTheme.swift`) and its shared
components (`apps/macos/NotchUI/Shared`: buttons, badges, list parts, agent logos and rows, chat rows and bubbles, your
messages), so both apps look the same; see *Shared with the iPhone* in [`docs/UI-COMPONENTS.md`](../../docs/UI-COMPONENTS.md).
To look at the screens without a Mac, run a Debug build with the launch arguments `-NookDemo` (sample sessions, chats and
a conversation) and optionally `-NookDemoShow agents|session|chats|chat`.
