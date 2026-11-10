# Roadmap: workspace

Larger pieces, roughly by value. Each fits Nook's architecture; none is started.

- **A usage widget on the iPhone.** Plan limits on the Home Screen; the `NookActivity` widget extension that now carries
  the Live Activity can host it.
- **Composer chips.** Context references (`[label](nook-context:…)`) as inline chips that delete as one, with undo grouped
  per kind of edit. Needs the composer moved from `TextField` to an `NSTextView`.
- **Muse as a managed provider**, and for Pi (which Nook runs over its RPC mode) a native fork and rollback through its
  `fork` command, reading its own session files for past sessions, and answering its select and input dialogs.
- **Browser.** Device presets with rotate and zoom, history and address suggestions per project, several tabs, and
  recording a page to a video an agent can read.
- **Terminal.** Split panes, and scrollback restored after a restart (bounded, with query/response escapes removed).
- **Diffs.** Syntax highlighting, a file tree, a choice of base branch, collapsed files, and review comments on a range of
  lines.
- **Companion.** A real diff review on the phone, dictation in the composer, a share extension and Home Screen quick
  actions, and a notice when the phone app is older than the Mac's protocol.
- **Model manifest:** see "Still open" in [`MODEL-MANIFEST.md`](MODEL-MANIFEST.md).
