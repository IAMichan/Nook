# Keybindings

The keys of Nook's panel (the notch, the main window and their sheets) are rules, not hard-coded shortcuts. A rule
says which **key** runs which **command**, and optionally **when**. Nook ships defaults; you can add your own rules in
`~/.nook/keybindings.json`. Settings › Shortcuts › **Panel keys** lists every command with the keys it answers to,
shows what your file could not use, and the keys that claim the same chord.

## How a key is handled

1. One local key monitor (`KeyCommandCenter`, `apps/macos/NotchUI/Components/KeyCommands.swift`) sees every key
   pressed in a Nook window.
2. It builds the **context** from what is on screen in that window:
   - `composerFocus`, `composerDraft` (the focused composer holds text), `turnRunning` (the agent is working): from the
     composer (`SessionComposer`, `ChatReplyField`) that has the keyboard;
   - `editableFocus` (a text is being edited) and `terminalFocus`: from the window's first responder;
   - `paletteOpen` (the agents' command palette), and `modelPickerOpen` / `diffOpen` once those views offer them.
3. `Keybindings.match` finds the command over `Keybindings.effective(user:)`: the defaults first, then your rules, and
   the **last** rule whose key and `when` both match wins.
4. The view that offers that command (`.keyCommand` / `.keyCommands`) runs it. When several views in the window offer
   it, the newest wins; a window-wide fallback (`priority: -1`, the main window's ⌘N) yields to any other.
5. A key no rule claims, or a command nothing on screen handles, goes on to the focused view as before. A key being
   composed by an input method and the keys of a mirrored Mac app are never taken.

## Defaults

| Key | Command | When | Does |
| --- | --- | --- | --- |
| ⌘↩ | `composer.send` | `composerFocus && !turnRunning` | Send (with the `/`, `@`, `#` list open: take the chosen line) |
| ⌘↩ | `composer.sendAlternate` | `composerFocus && turnRunning` | While the agent works: deliver the other way (steer instead of queue, or the reverse) |
| ⇧↩ | `composer.newline` | `composerFocus` | A new line in the box |
| ⌘S | `composer.stash` | `composerFocus` | Set the draft aside; in an empty box bring it back (or choose from several) |
| ⌥↑ / ⌥↓ | `composer.historyPrevious` / `composer.historyNext` | `composerFocus` | Walk through earlier messages from anywhere in the text (plain ↑ ↓ still do it from the edge) |
| ⇧⇥ | `composer.access` | `composerFocus` | In the Nook chat and the Double Tap field: what Nook may do by itself, to the next level (Ask first, Small things, More by itself); other composers leave ⇧⇥ to the field |
| ⇧⌘↩ | `queue.steerFirst` | `composerFocus && turnRunning` | Send the first queued message now |
| ⌘F | `chat.find` | `!terminalFocus` | Find in the session, or jump to the pull requests' search |
| ⌘K | `search.toggle` | `!terminalFocus` | Search everything, from every tab (also ⇧⌘F) |
| ⇧⌘K | `commandPalette.toggle` | `!terminalFocus` | The agents' command palette |
| ⌘N | `session.new` | `!terminalFocus` | A new Nook chat in the Nook list, a new agent session elsewhere in the main window |
| ⌘Z | `session.undo` | `!terminalFocus && !editableFocus` | Undo the last change to the agents' list (pin, settle…); in a text field ⌘Z undoes typing |
| ⇧⌘[ / ⇧⌘] | `session.previous` / `session.next` | | Not available yet |
| ⌘D | `diff.toggle` | `!terminalFocus` | Not available yet |
| ⇧⌘M | `modelPicker.toggle` | `!terminalFocus` | Not available yet |
| ⇧⌘S | `session.settle` | `!terminalFocus` | Not available yet |
| ⇧⌘P | `session.pin` | `!terminalFocus` | Not available yet |
| — | `session.interrupt` | | Unbound on purpose; not available yet |

"Not available yet" commands are listed so a rule can name them; nothing in Nook runs them today, so their keys pass
on to the focused view. Settings marks them the same way (`KeyCommandCenter.wiredCommands`).

Keys that are not commands stay with their view: Return, Tab, Escape and the plain arrows inside a field or a list,
⌘1–⌘3 for the main window's tabs, ⇧⌘F for search everything (besides ⌘K), and a sheet's `.cancelAction` / `.defaultAction`.

## Your own rules

`~/.nook/keybindings.json` is a JSON list:

```json
[
  { "key": "mod+shift+o", "command": "commandPalette.toggle" },
  { "key": "ctrl+enter", "command": "composer.send", "when": "composerFocus && !turnRunning" },
  { "key": "mod+z", "command": "session.undo", "when": "!editableFocus" }
]
```

- **key**: modifiers and a key joined by `+`. Modifiers: `mod` (⌘ on the Mac), `cmd`, `ctrl`, `alt`/`option`, `shift`.
  Keys: a character (`k`, `[`, `=`, `+` as `mod++`), or `enter`, `escape`, `tab`, `space`, `backspace`, `delete`,
  `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f20`.
- **command**: one of the commands above.
- **when** (optional): context names with `!`, `&&`, `||` and parentheses; an unknown name is false.

A rule adds a key; it does not take the default away (both keys work). A later rule on the same key wins when both
conditions hold, which is how a rule of yours overrides a default; Settings lists such pairs as conflicts so an
override is never a surprise. Rules Nook cannot read (no key, an unknown key, a broken `when`, not an object) are
skipped and listed in Settings with their position in the file; a file that is not a JSON list is ignored as a whole.
Nook reads the file when it starts, when it comes back to the front, and with **Reload** in Settings.

## For developers

- A new command: add its id to `Keybindings.commandIDs` (and a default to `Keybindings.defaults` if it has one), its
  name as `keys.command.<id>` in `Core/I18n+Keybindings.swift` in all five languages, offer it from the view with
  `.keyCommand("id") { … }` and add it to `KeyCommandCenter.wiredCommands`.
- A new context flag: add it to `Keybindings.contextKeys` and pass it in the `context:` of the view that knows it.
- Do not add `.keyboardShortcut` or `onKeyPress` with modifiers for something that is a command (see
  [`UI-COMPONENTS.md`](UI-COMPONENTS.md)). `KeybindingsTests` covers parsing, `when`, matching, conflicts, the file and
  the pressed-key mapping.
