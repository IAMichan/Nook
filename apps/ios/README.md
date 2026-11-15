# Nook for iOS (`NookCompanion`)

This directory contains **Nook Companion**, the iPhone app that shows which coding-agent sessions on your Mac need your attention, with support for approving or denying tool calls, answering questions, sending follow-up messages, and stopping sessions. It is Nook's panel made for iPhone, laid out as the Mac's panel with its three tabs along the bottom: Nook (home and chat with Nook), Agents (sessions you can start and follow) and Chats (your chat apps). Settings (your Mac and the connection, this iPhone's choices, plan usage, pairing) opens from the gear in every tab's header and Pull requests from the Agents header, each as a sheet. On an iPad with room the tabs become a split view, a section's list beside what you opened (see *iPad* in `docs/COMPANION.md`). It communicates directly with Nook on your Mac over your local Wi-Fi network; see [`docs/COMPANION.md`](../../docs/COMPANION.md).

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
  OverviewViews.swift    the calm overview on the Nook tab: what waits on you, what works, what is unread, and For you
  ConversationScroll.swift  the one scroll view every conversation reads in: opens at the end, follows only there
  SettingsViews.swift    Settings (a sheet from the header's gear): your Mac and the connection, this iPhone, usage, pairing, about
  SessionViews.swift     a session as a conversation, starting a new session
  ChatViews.swift        Nook's own chats, shared bubble and composer
  InboxViews.swift       the Mac's Chats tab: every chat app in one list, a chat as bubbles, answering WhatsApp
  ChatPictures.swift     the chats' own pictures from the Mac, kept in the caches folder
  LiveActivities.swift   Live Activity tokens for the Mac, the switch, updates while the app is open
  SplitViews.swift       the iPad: the split view at a regular width, where rows open, keyboard shortcuts
  ComposerDrop.swift     dragging pictures, a file, links and text into a composer
NookActivity/    widget extension: the Live Activity on the Lock Screen and in the Dynamic Island
Shared/          what the app and the extension share (ActivityKit attributes, how a phase looks)
```

The wire protocol, ChaCha20-Poly1305 sealing, and SHA-256/HMAC helpers are shared with the macOS app via [`packages/protocol`](../../packages/protocol).

The design is shared too: the app compiles the Mac's theme (`apps/macos/UI/Theme/NookTheme.swift`) and its shared
components (`apps/macos/UI/Shared`: buttons, badges, list parts, agent logos and rows, chat rows and bubbles, your
messages), so both apps look the same; see *Shared with the iPhone* in [`docs/UI-COMPONENTS.md`](../../docs/UI-COMPONENTS.md).
To look at the screens without a Mac, run a Debug build with the launch arguments `-NookDemo` (sample sessions, chats and
a conversation) and optionally `-NookDemoShow agents|session|chats|chat`.
