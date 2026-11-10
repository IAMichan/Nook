# Roadmap: workspace

Larger pieces, roughly by value. Each fits Nook's architecture; none is started.

- **Composer chips.** Context references (`[label](nook-context:…)`) as inline chips that delete as one, with undo grouped
  per kind of edit. Needs the composer moved from `TextField` to an `NSTextView`.
- **Pi and Muse as managed providers.** Pi speaks LF-delimited JSON RPC over stdio (`prompt`, `get_state`, `set_model`,
  `fork`, `compact`); Nook would add a `RunProvider` and inject the workspace bridge as a Pi extension.
- **Browser.** Device presets with rotate and zoom, history and address suggestions per project, several tabs, and
  recording a page to a video an agent can read.
- **Terminal.** Split panes, and scrollback restored after a restart (bounded, with query/response escapes removed).
- **Diffs.** Syntax highlighting, a file tree, a choice of base branch, collapsed files, and review comments on a range of
  lines.
- **Companion.** Dictation on the Mac (*transcribe on the Mac*): the phone's dictation is on-device, and audio is too
  heavy for the sealed companion channel to carry cheaply, so it stays on the iPhone.
- **Model manifest:** see "Still open" in [`MODEL-MANIFEST.md`](MODEL-MANIFEST.md).
