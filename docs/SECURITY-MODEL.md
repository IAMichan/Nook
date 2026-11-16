# Security model: what Nook can reach, and how you stay in control

Nook keeps the overview of everything that needs your attention: people, coding agents, music, your calendar. To do
that it needs real access to your Mac and your accounts. This page says plainly what that access is, why Nook runs
without the macOS App Sandbox, what protects you instead, and how you take any of it back.

The short version:

- Nook asks for each macOS permission only for the feature that needs it, and works without any of them.
- Every account you link is listed in **Settings › Privacy › Access**, with one click to manage or remove it.
- Keys and tokens live in your Keychain; Nook's own data lives in a folder only your user can open.
- Nothing that sends, changes or runs happens without your click, and every action is in the activity log.
- Nook has no analytics. Data leaves your Mac only to the AI provider and the services you choose.

## Why Nook runs without the App Sandbox

The App Sandbox limits an app to its own container. That is a good default for most apps, but it rules out what Nook is
for. Inside the sandbox Nook could not:

- **Start and follow coding agents.** Claude Code, Codex, Gemini CLI and the other agents are programs in your home
  folder that Nook starts, watches and stops, in the project folders you pick, with their own settings under `~/.claude`,
  `~/.codex` and so on.
- **Read the screen and help in other apps.** Screen context, autocomplete and taking over a task use the Accessibility
  API on other apps' windows, which a sandboxed app cannot use.
- **Control other apps.** Sending a message through Messages, controlling Spotify and Music, and building an update in
  Xcode use Apple Events to apps that are not known in advance.
- **Offer its local bridge.** Agents' hooks, the `nook` MCP tools and the chat helper talk to Nook over Unix sockets and
  `127.0.0.1` in Nook's own folder.

This is why tools that run local coding agents, such as terminal apps, launchers and the agent vendors' own desktop
apps, also run without the sandbox. Turning it on would remove these features rather than make them safer.

## What protects you instead

| Layer | What it does |
| --- | --- |
| **Hardened Runtime, without exceptions** | Other programs cannot inject code into Nook or attach a debugger to inherit its permissions. Nook does not use the exceptions that weaken this (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`). |
| **A short list of entitlements** | Microphone, Apple Events, Calendars, Contacts and outgoing network connections. Nothing else. See `apps/macos/project.yml`. |
| **Signed and notarized releases** | Release builds are signed with a Developer ID and checked by Apple's notary service (`.github/workflows/release.yml`). The code is open source under the MIT license, so anyone can check what a build does. |
| **macOS asks you** | Screen Recording, Accessibility, Input Monitoring, Calendars, Reminders, Contacts, the microphone, Full Disk Access and Automation are each granted by you in a macOS dialog or in System Settings. Nook asks for one only when you turn on the feature that needs it. |
| **Approval for every action** | Messages, emails, calendar changes, webhooks and shell commands wait for your **Allow**. `CommandRisk` refuses destructive commands whatever an agent's own flags say, and Plan mode is read-only. |
| **An activity log** | Every action Nook carries out is written to a local log you can search and clear in **Settings › Privacy › Activity log** (kept for 90 days). |
| **Untrusted text stays data** | Screen text, emails, calendar items, web pages and tool output are passed to the AI as data, with instructions never to follow commands found in them. Memory learns only from what you write yourself. |
| **Private local channels** | The sockets in Nook's folder are `0600` and check that the caller is your own user. The chat helper listens on `127.0.0.1` only, behind a token Nook makes at every start. `NetworkGuard` blocks requests to private and loopback addresses (SSRF). |

## Where your data and secrets are kept

- **Keys and tokens** (AI providers, linked services, MCP servers, paired devices) are kept in your login Keychain, in a
  single item only Nook may read (`SecretStore`). Items in the login Keychain stay on this Mac: Apple syncs only the
  data-protection Keychain through iCloud Keychain. Removing a connection deletes its secret.
- **Nook's own data** (`~/Library/Application Support/Nook`: memory, chats with Nook, the activity log, chat history)
  is in a folder with permissions `0700`, so other users of the Mac cannot open it. Database and secret files in it are
  `0600`.
- **Chat accounts** linked through Nook's chat helper keep their sessions in `Application Support/Nook/ChatHelper`, on
  this Mac only.
- **Coding agents** keep their own sign-in and history in their own folders, as they do without Nook. They get their
  own secrets only, never Nook's keys.

## What leaves your Mac

- **To the AI you choose.** With a model on your Mac (the built-in MLX models, Apple Foundation Models, Ollama or LM
  Studio) nothing leaves it. With a cloud provider, only what a question needs is sent: your question, relevant
  snippets and, if you allow it, screen text. The privacy level filters secrets first; sources marked **Only on this
  Mac** never go. See **Settings › Privacy**.
- **To the services you link.** Nook talks to GitHub, Notion, Slack and the rest directly, with your own account, for
  what you ask.
- **To your iPhone.** The companion talks to the Mac over your own network; the optional relay only passes sealed bytes
  it cannot read (see [`COMPANION.md`](COMPANION.md)).
- **Nothing else.** Nook has no analytics or usage tracking. The only telemetry is an OpenTelemetry export you set up
  yourself, to your own receiver.

## Seeing and taking back access

**Settings › Privacy › Access** is the one overview:

- **Permissions:** every macOS permission with its state. A granted one has **Revoke…**, which opens the right page of
  System Settings (macOS lets only you turn a permission off).
- **Linked accounts and services:** everything Nook is signed in to, from chat apps to your own MCP servers. **Manage**
  opens its sheet, where you switch it off or remove it.
- **Apps Nook never reads:** apps left out of screen reading, autocomplete and taking over. Password managers are
  always left out.

The other Privacy pages hold the privacy level, the sources only a model on this Mac may read, and the activity log.

## Testing Nook before you link everything

A good way to start:

1. Start with a model on your Mac, so nothing leaves it while you look around.
2. Grant only the permissions for the features you try, and link one account at a time.
3. Mark sensitive sources (mail, memory, the screen) as **Only on this Mac** before you add a cloud provider.
4. Keep coding agents on **Allow edits** (the default: commands wait for you) or **Ask**, never **Allow everything**,
   and look at the activity log now and then.

## Reporting a problem

Found a way around any of this? Please report it privately, as [`SECURITY.md`](../SECURITY.md) describes.
