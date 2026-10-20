# CLAUDE.md — Claude Code Instructions for Nook

Please read and follow all rules in [AGENTS.md](AGENTS.md).

## Key Reminders for Claude

1. **Always use English for Git & Code (even when prompted in Dutch):**
   - **Commit messages** (subject and body) must always be in **English**.
   - **Pull request titles and descriptions** must always be in **English** (using [`.github/pull_request_template.md`](.github/pull_request_template.md)).
   - **Branch names**, **Swift identifiers**, **code comments**, **docstrings**, and **documentation** must always be in **English**.
   - You may reply to the user in the language they used in chat, but every artifact written to the repository, git history, or GitHub PR must be in **English**.
2. **Default App Language & `I18n`:**
   - The default language of Nook is **English (`en`)**.
   - Every user-facing string in `apps/macos` must go through `tr("key")` and be translated in all 5 supported languages (`en`, `nl`, `de`, `fr`, `es`) in `apps/macos/Core/I18n*.swift`.
3. **UI consistency (one design, one layout):**
   - Every view in `apps/macos/NotchUI` and `apps/macos/App` takes its colors, type, radii, and spacing from `NookTheme`: use `NookTheme.TextStyle` or `NookTheme.font`/`mono`/`rounded`, the named colors, `NookTheme.Radius`, and `NookTheme.Spacing`. Never write `Font.system(size:)`, `Color(hex:)`, or a numeric corner radius inline in a view.
   - Reuse the shared components in [`docs/UI-COMPONENTS.md`](docs/UI-COMPONENTS.md) and follow its checklist; a pattern used a third time becomes a component there.
   - The notch, the main window, and sheets share `PanelView`; Settings is the only configuration surface. Do not build a second layout.
   - Run `./scripts/ui-lint.sh` after a UI change. `UIConsistencyTests` enforces the same rules in the test suite; when a file must draw its own colors, add it to the allow-list in both the test and the script with a reason.
4. **Verification:**
   - Run `./scripts/core-tests.sh` (which includes `I18nCoverageTests` and `UIConsistencyTests`) before creating a commit or pull request.
   - Run `./scripts/ui-lint.sh` whenever `apps/macos/NotchUI` or `apps/macos/App` changed.
   - If you add or remove files in `apps/macos` or `apps/ios`, update `project.yml` if needed and regenerate the project with `xcodegen`.
