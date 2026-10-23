# Roadmap: workspace

Larger pieces, roughly by value. Each fits Nook's architecture; none is started.

- **A usage widget on the iPhone.** Plan limits on the Home Screen; the `NookActivity` widget extension that now carries
  the Live Activity can host it.
- **Composer chips.** Context references (`[label](nook-context:…)`) as inline chips that delete as one, with undo grouped
  per kind of edit. Needs the composer moved from `TextField` to an `NSTextView`.
- **Pi and Muse as managed providers.** Pi speaks LF-delimited JSON RPC over stdio (`prompt`, `get_state`, `set_model`,
  `fork`, `compact`); Nook would add a `RunProvider` and inject the workspace bridge as a Pi extension.
- **Browser.** Device presets with rotate and zoom, history and address suggestions per project, several tabs, and
  recording a page to a video an agent can read.
- **Terminal.** Split panes, and scrollback restored after a restart (bounded, with query/response escapes removed).
- **Diffs.** Syntax highlighting, a file tree, a choice of base branch, collapsed files, and review comments on a range of
  lines.
- **Portable handoffs.** Carry selected messages verbatim when switching agents, and point at the rest through
  `session_read`, instead of only a summary.
- **Companion.** A real diff review on the phone, dictation in the composer, a share extension and Home Screen quick
  actions, and a notice when the phone app is older than the Mac's protocol.
- **SSH password sign-in** through `SSH_ASKPASS` with the password in the Keychain.
- **Model manifest:** see "Still open" in [`MODEL-MANIFEST.md`](MODEL-MANIFEST.md).
