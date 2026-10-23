# Contributing to Nook

Thanks for your interest in contributing to Nook! Bug reports, feature ideas, translations, testing on real hardware, and pull requests are all welcome. You don't need to be a Swift expert, and **you don't need a Mac**: a large part of Nook is Rust, Svelte, and TypeScript that builds on Windows and Linux.

## Ways to Contribute

| You have… | You can help with… | Start here |
|---|---|---|
| **A Mac** | The native macOS app (Swift, SwiftUI/AppKit), the primary and most complete version of Nook | [macOS](#macos) |
| **A Windows PC** | Run the Tauri app on real Windows hardware for the first time and report what works; fix what doesn't | [Windows, Linux & Android](#windows-linux--android-tauri) |
| **A Linux machine** | The Tauri app (Rust core, Svelte 5 UI), Wayland support, packaging | [Windows, Linux & Android](#windows-linux--android-tauri) |
| **An Android phone** | Install the APK from CI on a real device and report what works | [Windows, Linux & Android](#windows-linux--android-tauri) |
| **An iPhone** | The Nook Companion app (SwiftUI) | [iPhone Companion](#iphone-companion) |
| **A second language** | Review or improve the Dutch, German, French, or Spanish strings, or translate the Tauri app (Dutch-only today) | [Translations](#translations) |
| **An eye for clear writing** | Docs, the README, error messages, onboarding copy | [Docs](#docs) |
| **Ten minutes** | Try Nook and open an issue about anything confusing or broken; give the repo a ⭐ | [Reporting Issues](#reporting-issues) |

Looking for something concrete? Check the issues labeled [`good first issue`](https://github.com/IAMichan/nook/labels/good%20first%20issue) and [`help wanted`](https://github.com/IAMichan/nook/labels/help%20wanted). Every row marked ○ or ◐ in [docs/TAURI.md](docs/TAURI.md) and every item in [docs/ROADMAP.md](docs/ROADMAP.md) is also open. If you want to work on something, comment on the issue (or open one) first so nobody does the same work twice.

## Your First Pull Request

1. **Fork** the repository and clone your fork.
2. **Create a branch:** `git checkout -b fix/short-description` (or `feat/…`, `docs/…`, `i18n/…`).
3. **Build and run** the part you're changing (see the platform sections below).
4. **Make your change** and keep it focused on one topic.
5. **Run the checks** for what you touched:
   - macOS app or Swift core: `./scripts/core-tests.sh` (runs on Linux too), and `./scripts/ui-lint.sh` when you changed `apps/macos/NotchUI` or `apps/macos/App`.
   - Tauri app: the `npm` and `cargo` checks under [Windows, Linux & Android](#windows-linux--android-tauri).
6. **Open a pull request** using the [PR template](.github/pull_request_template.md). Commits, branches, code, comments, and docs are written in English.
7. **Link the issues it resolves.** Before opening the pull request, check the [open issues](https://github.com/IAMichan/nook/issues) for any your change resolves, and list them under *Related issues* as `Closes #123` so they close on merge. Use `Part of #123` when the issue stays open.

CI runs on every pull request, and an automated reviewer (CodeRabbit) leaves comments. Don't worry if CI or a review asks for changes; that's normal, and maintainers are happy to help you get it green.

## Building Locally

### macOS

Requires an Apple Silicon Mac with **macOS 15+** and **Xcode 26+**.

```sh
brew install xcodegen
cd apps/macos
xcodegen
open Nook.xcodeproj
```

Or build from the command line (inside `apps/macos`):

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

> **Signing:** `xcodegen` runs `Config/local-signing.sh`, which signs local builds with the Apple Development certificate in your keychain (written to the untracked `Config/Signing.local.xcconfig`). Without one, it creates a self-signed "Nook Local Signing" identity in your login keychain once, and the scheme's post-build action re-signs every build with it, so macOS keeps the permissions you granted (set `NOOK_NO_LOCAL_IDENTITY=1` to stay ad hoc). A free Apple ID under Xcode › Settings › Accounts works too.

> **Note:** Whenever you add, move, or remove a source file, run `xcodegen` again (or `./update.sh` in the repository root). The generated `.xcodeproj` files are intentionally not tracked in Git.

### Windows, Linux & Android (Tauri)

Nook for Windows, Linux, and Android is a single [Tauri 2](https://tauri.app) app in [`apps/tauri`](apps/tauri): a Rust core (`core/`, testable without a window), the app shell (`src-tauri/`), and a Svelte 5 + TypeScript interface (`src/`). The macOS app is the specification: names, behavior, and copy follow it. See [`apps/tauri/README.md`](apps/tauri/README.md) for the layout and [docs/TAURI.md](docs/TAURI.md) for what has been ported so far.

Requirements: [Rust](https://rustup.rs) (rustup installs the version in `rust-toolchain.toml`), [Node.js](https://nodejs.org) 22, and the [Tauri prerequisites](https://tauri.app/start/prerequisites/) for your platform.

```sh
cd apps/tauri
npm ci
npm run tauri dev          # run with hot reload
```

Run the same checks as CI before opening a pull request:

```sh
npm run check && npm test && npm run build
cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

Especially welcome right now:

- **Windows testers.** The Windows build compiles in CI but has never been run on a real Windows PC. Install it, try the bar, hotkeys, screen reading, and autocomplete, and open an issue with what you find.
- **Android testers.** Download the unsigned APK from the latest **Android** CI job and try it as a companion.
- **Ports.** Pick a ○ or ◐ row in [docs/TAURI.md](docs/TAURI.md) and port it from the Mac app.

### iPhone Companion

```sh
brew install xcodegen
cd apps/ios
xcodegen
open NookCompanion.xcodeproj
```

See [`apps/ios/README.md`](apps/ios/README.md) and [docs/COMPANION.md](docs/COMPANION.md).

## Translations

- **macOS app:** every user-facing string goes through `tr("key")` and lives in `apps/macos/Core/I18n*.swift` in five languages (`en`, `nl`, `de`, `fr`, `es`). English is the default. Native speakers reviewing the German, French, or Spanish strings are very welcome; a PR that only improves wording is a great first contribution. `I18nCoverageTests` (part of `./scripts/core-tests.sh`) checks that no key is missing and that placeholders such as `%@` and `%ld` match.
- **Tauri app:** the interface is Dutch-only today. Bringing it to English and the other Mac languages is one of the most useful things you can do; check the [`help wanted`](https://github.com/IAMichan/nook/labels/help%20wanted) issues or open one to coordinate.

## Docs

All documentation is in English and lives in the [README](README.md), this file, and [`docs/`](docs). Fixing an unclear sentence, a broken link, or an outdated step is always welcome and needs no build.

## Architecture Overview

Nook is a monorepo with platform apps in `apps/` and shared modules in `packages/` (see [docs/MONOREPO.md](docs/MONOREPO.md)). The macOS app lives in `apps/macos`; paths below are relative to `apps/macos`:

- **`AppModel` is composition-only:** Feature logic belongs in dedicated types or modular `AppModel+….swift` extensions (chat, plans, voice, cards, agents, accounts, workspace, etc.), not directly in `AppModel.swift`.
- **Single path to the brain:** Chat, cards, and proactive assistance (*Think Along*) all go through the same `prepareRun` pipeline. Do not introduce parallel execution paths to the LLM.
- **Self-describing connectors:** New integrations register themselves via `SourceCatalog.register` (source metadata, tools, aliases, intents) without hardcoding central switch tables.
- **Internationalization (`I18n`):** Every user-facing string goes through `tr("key")` and must be present in all five supported languages (`en`, `nl`, `de`, `fr`, `es`), with English (`en`) as the default language. `I18nCoverageTests` verifies that no keys are missing and that format placeholders (`%@`, `%ld`, etc.) match across all languages.
- **One design:** Views take colors, type, radii, and spacing from `NookTheme` and reuse the shared components in [docs/UI-COMPONENTS.md](docs/UI-COMPONENTS.md). `./scripts/ui-lint.sh` and `UIConsistencyTests` enforce this.
- **Secrets in Keychain only:** Always store API keys, tokens, and webhook secrets via `SecretStore` (aliased as `Keychain`)—never in plain files or `UserDefaults`.

## Running Tests

```sh
# Inside apps/macos
xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:NookTests test
```

Core logic (source scoping, action validation, tool loop, session registry, workspace models, and localization coverage) relies only on `Foundation` and can also be tested on Linux via `./scripts/core-tests.sh`.

## Pull Request Guidelines

- Keep PRs focused on a single topic or fix.
- Link every issue the PR resolves with `Closes #123` (or `Part of #123` for partial work).
- Ensure the GitHub Actions CI build and test suite pass.
- Match the surrounding style and conventions (Swift, Rust, or Svelte).
- **Explicit user approval:** Any action that mutates user data or executes on the system (calendar, mail, shell commands, webhooks, system settings) must go through an interactive confirmation card/plan approved by the user and write an entry to the `audit` table in `nook.sqlite`.
- **Untrusted input:** Always treat external text (screen OCR, calendar events, emails, web pages, tool outputs, agent hooks) as untrusted data, never as instructions.
- **Using a coding agent?** That's welcome. Agents working in this repo should follow [AGENTS.md](AGENTS.md); you remain responsible for reviewing what you submit.

## Reporting Issues

Please use the GitHub issue templates for bug reports and feature requests. **Do not** report security vulnerabilities in public issues—see [SECURITY.md](SECURITY.md) for private disclosure instructions.

By participating, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
