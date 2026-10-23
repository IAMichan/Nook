# What Nook can learn from Code

[Code]() is an open-source GUI for coding agents (Codex, Claude Code). Its
workspace overlaps with Nook's Agents tab, so its code is a good source of lessons for the workspace. This page records
what we took from it and where it lives in Nook.

> Re-implement ideas in Nook's own style; do not copy code. Check Code's license before reusing anything literal.

## Keybindings

**In Code** (`apps/web/src/keybindings.ts`): shortcuts are rules `{ key, command, when }`. One key handler builds a
context (`terminalFocus`, `terminalOpen`, …), resolves the pressed chord against the defaults plus the user's
`keybindings.json` (the last matching rule wins), and dispatches the command. Bad rules are skipped and reported;
`mod` is ⌘ on the Mac and Ctrl elsewhere.

**In Nook** (implemented):

- `Services/Workspace/Keybindings.swift` (Foundation-only, tested in `KeybindingsTests`): `KeyChord` (parse, format,
  `pressed` from a key event's unshifted characters and key code), `WhenExpression`, `KeybindingRule`,
  `Keybindings.defaults`, `commandIDs`, `contextKeys`, `match`, `conflicts`, `load` / `read` of
  `~/.nook/keybindings.json`, `unknownCommands` and `chords(for:)`.
- `NotchUI/Components/KeyCommands.swift`: `KeyCommandCenter`, the one local key monitor for the panel. It builds the
  context (`composerFocus`, `composerDraft`, `turnRunning` from the focused composer; `editableFocus`, `terminalFocus`
  from the first responder; `paletteOpen` from the agents' tab), matches over `Keybindings.effective(user:)` and runs
  the handler a view offers with `.keyCommand` / `.keyCommands`, scoped to the window the key was pressed in.
- The hard-coded shortcuts it covers are gone: ⌘Return, ⌘S and the history keys in `SessionComposer`, ⌘Return in
  `ChatReplyField`, the hidden ⌘F buttons in `AgentRunPanel` and `PullRequestsPanel`, ⌘K in `AgentsTab`, ⌘N in
  `WorkspaceView` and `NookConversationList`, ⌘Z in `AgentInboxList`. ⇧⌘Return sends the first queued message.
- Settings › Shortcuts › **Panel keys** lists every command with its keys, marks the commands nothing runs yet, and
  shows the file's state, the rules it skipped (with their position), unknown commands and conflicts.

**Differences from Code**, on purpose:

- A rule adds a key; the default stays (Code does the same). ⌘S (`composer.stash`) asks only for `composerFocus`,
  because in an empty composer it brings a stashed draft back.
- A matched command that nothing on screen handles lets the key go on to the focused view, so a rule for a command
  that is not wired yet never swallows a key.
- Keys inside a field or a list (Return, Tab, Escape, plain arrows) stay with that view; they are not commands.

See [`KEYBINDINGS.md`](KEYBINDINGS.md) for the defaults, the file format and how to add a command.
