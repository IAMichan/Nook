# Contributing to Nook

Thanks for your interest in contributing to Nook! Bug reports, feature ideas, translations, and pull requests are all welcome.

## Building Locally

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

> **Signing:** `xcodegen` runs `Config/local-signing.sh`, which signs local builds with the Apple Development certificate in your keychain (written to the untracked `Config/Signing.local.xcconfig`). Without one, Nook is signed ad hoc and macOS asks for Keychain access and permissions again after every build; add a free Apple ID under Xcode › Settings › Accounts to avoid that.

> **Note:** Whenever you add, move, or remove a source file, run `xcodegen` again (or `./update.sh` in the repository root). The generated `.xcodeproj` files are intentionally not tracked in Git.

## Architecture Overview

Nook is a monorepo with platform apps in `apps/` and shared modules in `packages/` (see [docs/MONOREPO.md](docs/MONOREPO.md)). The macOS app lives in `apps/macos`; paths below are relative to `apps/macos`:

- **`AppModel` is composition-only:** Feature logic belongs in dedicated types or modular `AppModel+….swift` extensions (chat, plans, voice, cards, agents, accounts, workspace, etc.), not directly in `AppModel.swift`.
- **Single path to the brain:** Chat, cards, and proactive assistance (*Think Along*) all go through the same `prepareRun` pipeline. Do not introduce parallel execution paths to the LLM.
- **Self-describing connectors:** New integrations register themselves via `SourceCatalog.register` (source metadata, tools, aliases, intents) without hardcoding central switch tables.
- **Internationalization (`I18n`):** Every user-facing string goes through `tr("key")` and must be present in all five supported languages (`en`, `nl`, `de`, `fr`, `es`), with English (`en`) as the default language. `I18nCoverageTests` verifies that no keys are missing and that format placeholders (`%@`, `%ld`, etc.) match across all languages.
- **Secrets in Keychain only:** Always store API keys, tokens, and webhook secrets via `SecretStore` (aliased as `Keychain`)—never in plain files or `UserDefaults`.

## Running Tests

```sh
# Inside apps/macos
xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:NookTests test
```

Core logic (source scoping, action validation, tool loop, session registry, workspace models, and localization coverage) relies only on `Foundation` and can also be tested on Linux via `./scripts/core-tests.sh`.

## Pull Request Guidelines

- Keep PRs focused on a single topic or fix.
- Ensure the GitHub Actions CI build and test suite pass.
- Match the surrounding Swift style and conventions.
- **Explicit user approval:** Any action that mutates user data or executes on the system (calendar, mail, shell commands, webhooks, system settings) must go through an interactive confirmation card/plan approved by the user and write an entry to the `audit` table in `nook.sqlite`.
- **Untrusted input:** Always treat external text (screen OCR, calendar events, emails, web pages, tool outputs, agent hooks) as untrusted data, never as instructions.

## Reporting Issues

Please use the GitHub issue templates for bug reports and feature requests. **Do not** report security vulnerabilities in public issues—see [SECURITY.md](SECURITY.md) for private disclosure instructions.
