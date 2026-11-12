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
   - `panelFocus`: the first responder lies in a session's side or bottom panel (or the diff or file beside the
     conversation), from the window's focus areas (`FocusAreas`);
   - `listFocus`: the Agents list has the keyboard (after F6);
   - `paletteOpen` (the agents' command palette), `modelPickerOpen` (a model picker is open), and `diffOpen` once that
     view offers it.
3. `Keybindings.match` finds the command over `Keybindings.effective(user:)`: the defaults first, then your rules, and
   the **last** rule whose key and `when` both match wins.
4. The view that offers that command (`.keyCommand` / `.keyCommands`) runs it. When several views in the window offer
   it, the newest goes first; a handler that lets the key go (returns false) hands it to the one before it. A
   window-wide fallback (`priority: -1`, the main window's ⌘N, the terminal keys) yields to any other.
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
| ⌘Z / ⇧⌘Z | `composer.undo` / `composer.redo` | `composerFocus` | Undo and redo in the draft: typing, a chip put in or deleted (it comes back with its whole reference), a paste, a dictation |
| ⇧⌘V | `composer.pasteAsText` | `composerFocus` | Paste a big text as text you can edit instead of as an attachment (a paste that would push the message past its limit of 120,000 characters still goes aside) |
| ⇧⌘↩ | `queue.steerFirst` | `composerFocus && turnRunning` | Send the first queued message now |
| ⌘F | `chat.find` | `!terminalFocus` | Find in the session (also one read from its transcript), or jump to the pull requests' search |
| ⌘K | `search.toggle` | `!terminalFocus` | Search everything, from every tab (also ⇧⌘F) |
| ⇧⌘K | `commandPalette.toggle` | `!terminalFocus` | The agents' command palette |
| ? (⇧/) | `shortcuts.cheatSheet` | `!editableFocus && !composerFocus && !terminalFocus` | The shortcut cheat sheet: every command with its keys as they are now, grouped, with a filter; "Change keys" opens Settings › Shortcuts. ⌘/ opens it from anywhere (also while typing) |
| ⌘N | `session.new` | `!terminalFocus` | A new Nook chat in the Nook list, a new agent session elsewhere in the main window |
| ⌘Z | `session.undo` | `!terminalFocus && !editableFocus && !composerFocus` | Undo the last change to the agents' list (pin, settle…); in a text field ⌘Z undoes typing |
| ⇧⌘T | `panel.reopenClosed` | `!terminalFocus` | Reopen the tab closed last: a session's side or bottom panel tab (in the panel it was in, a pull request tab with its pull request), or a tab on the Pull requests page |
| ⇧⌘L | `selection.quote` | `!terminalFocus && !editableFocus` | Words selected in an agent's answer go with your next message, as a chip above the composer; the chip can carry your own note, and a click on it jumps back to the passage |
| ⌘L | `selection.ask` | `!terminalFocus && !editableFocus` | The same, and the keyboard goes to the composer to ask about them |
| ⇧⌘[ / ⇧⌘] | `session.previous` / `session.next` | | The chat above or below on Chats; the repository tab on the left or right on the Actions page |
| ⌘D | `diff.toggle` | `!terminalFocus` | The Changes tab on the latest turn (or the branch), and again to close it |
| ⇧⌘M | `modelPicker.toggle` | `!terminalFocus` | Opens the model picker of the composer on screen (↑ ↓ move over the models, Return picks, Escape closes) |
| ⌘1–⌘9 | `modelPicker.pick1` … `modelPicker.pick9` | `modelPickerOpen` | In the open model picker: picks the nth model listed (a disabled one keeps its number); the session jumps step aside meanwhile |
| ⇧⌘↑ / ⇧⌘↓ | `modelPicker.previousPlace` / `modelPicker.nextPlace` | `modelPickerOpen` | In the open model picker: the place before or after the shown one in its rail, round the ends |
| ⇧⌘E | `effortPicker.toggle` | `!terminalFocus` | Opens the effort picker of the composer on screen, when its agent has levels |
| ⇧⌘A | `permissionPicker.toggle` | `!terminalFocus` | Opens the access picker of the composer on screen |
| — | `effort.increase` / `effort.decrease` | | Unbound on purpose: one effort level up or down in the composer on screen without opening the picker (`EffortStep`; for an agent that lists a model per level, the next model of that family) |
| ⌥⌘5 | window capture (Settings › Shortcuts) | | Captures the front window: its picture and its text (Accessibility, else read from the picture) go to the composer of the session you work in, or to the Nook chat (Settings › Shortcuts chooses). Needs Screen Recording |
| ⇧⌘S | `session.settle` | `!terminalFocus` | Settles the open session, or brings a settled one back |
| ⇧⌘P | `session.pin` | `!terminalFocus` | Pins the open session, or unpins it |
| — | `session.interrupt` | | Unbound on purpose: stops the open session's turn (a session Nook runs); also in the command palette |
| ⌘[ / ⌘] | `session.back` / `session.forward` | `!terminalFocus` | Back and forward through the sessions you opened (sessions that are gone are skipped) |
| ⌘1–⌘9 | `session.jump1` … `session.jump9` | `!modelPickerOpen` | On the Agents tab: the first nine rows of the list as shown; hold ⌘ for a moment to see each row's number. Elsewhere (and past the end of the list) ⌘1–⌘3 switch the main window's tabs |
| F2 | `session.rename` | `!editableFocus && !terminalFocus` | Renames the session the list's keyboard is on, else the open one (sessions Nook runs) |
| ⌘O | `session.openInEditor` | `!terminalFocus` | Opens the open session's folder in your editor (Settings › Workspace), else in Finder |
| ⇧⌘C | `session.copyReference` | `!terminalFocus && !editableFocus` | Copies the open session's folder and branch: `/code/app (feature/x)` |
| ⌥⌘↩ | `composer.startInBackground` | `composerFocus` | In the new-session box: starts the session without opening it, and keeps a fresh box with the same folder, agent and worktree choices |
| ⌘↩ | `composer.send` | `composerFocus && !turnRunning` | In the new-session box, the same as ⌥⌘↩; Return starts the session and opens it |
| ⌘B | `sidebar.toggle` | `!terminalFocus` | Puts the Agents list away, or brings it back |
| ⌘J | `terminal.toggle` | | The terminal in the bottom panel under the session, and again to put it away |
| ⌥⌘B | `sidePanel.toggle` | | Puts the side panel away with its tabs, or opens it again on what it showed |
| ⇧⌘B | `sessionPanel.toggle` | `!terminalFocus` | The session panel beside the conversation, where the window has room for it |
| ⌘W | `tab.close` | `terminalFocus \|\| panelFocus` | With a terminal focused: closes that terminal; with a side or bottom panel focused: closes its tab in view. Anywhere else ⌘W closes the window as before |
| ⌘D / ⇧⌘D | `terminal.splitRight` / `terminal.splitDown` | `terminalFocus` | A new terminal in the same folder beside or under the focused one (up to four in a split) |
| F6 / ⇧F6 | `focus.next` / `focus.previous` | | The keyboard to the next or previous part of the window: the session list, the conversation, the composer, the side panel, the bottom panel (only the parts on screen, round the end, back where it was in each part) |

Every command is wired today (`KeyCommandCenter.wiredCommands`); a command that a future build lists without a view
that runs it shows as "not available yet" in Settings, and its keys pass on to the focused view.

Keys that are not commands stay with their view: Return, Tab, Escape and the plain arrows inside a field or a list,
⌘1–⌘3 for the main window's tabs outside the Agents tab, ⇧⌘F for search everything (besides ⌘K), and a sheet's
`.cancelAction` / `.defaultAction`.

In a session composer that shows a suggested next prompt (ghost text after a finished turn, Settings › Sessions ›
Text generation), Tab puts the suggestion in the box and Escape dismisses it; typing anything dismisses it too.

## Keys in the Agents list and the pickers

- After F6 the Agents list has the keyboard: ↑ ↓ move the lit row without opening it, Return opens it, ← folds its
  project (or its Snoozed or Settled shelf) and → unfolds it, F2 renames it.
- The command palette (⇧⌘K) lists, in groups: recent sessions (the ones you open often and lately first; for three weeks, the session you last picked
  after typing the same words comes first when you type them again, `PalettePicks`), what you
  can do with the open session (pin, settle, snooze, rename, fork, copy the branch, path or both, open in your editor,
  show the changes, interrupt), navigation (a new session, **New session in…** with your projects, back and forward,
  the pages and panels) and settings. Each command shows its key; `>` first leaves only the actions.
- A model picker: ↑ ↓ move over the models that can be picked, Return picks the lit one (at first the first match of
  the search).

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

A rule adds a key; it does not take the default away (both keys work), unless a rule switches the default off: its
command is the default's with a `-` before it, on the default's key (`{ "key": "mod+shift+m", "command":
"-modelPicker.toggle" }`). A later rule on the same key wins when both
conditions hold, which is how a rule of yours overrides a default; Settings lists such pairs as conflicts so an
override is never a surprise. Rules Nook cannot read (no key, an unknown key, a broken `when`, not an object) are
skipped and listed in Settings with their position in the file; a file that is not a JSON list is ignored as a whole.
Nook reads the file when it starts, when it comes back to the front, and with **Reload** in Settings.

You rarely need to edit the file by hand: Settings › Shortcuts › **Panel keys** has a search over the commands and
their keys, and per command **Record**, which takes the next key you press (with ⌘, ⌃ or ⌥, or a function key;
Escape cancels) and writes it to the file with the default's `when`, together with a rule that switches the old default
key off (`KeybindingEdits`). A key that another command also claims in the same place is saved with a warning that names
that command. **Reset** takes your rules for that command out of the file again. Recording and resetting leave every
other entry of the file as it was; a file that is not a JSON list is never overwritten.

## For developers

- A new command: add its id to `Keybindings.commandIDs` (and a default to `Keybindings.defaults` if it has one), its
  name as `keys.command.<id>` in `Core/I18n+Keybindings.swift` in all five languages, offer it from the view with
  `.keyCommand("id") { … }` and add it to `KeyCommandCenter.wiredCommands`.
- A new context flag: add it to `Keybindings.contextKeys` and pass it in the `context:` of the view that knows it.
- A part of a window F6 should step to: mark it with `.focusArea(_:)` (`FocusAreas.swift`); a part SwiftUI focuses
  (a list with a `@FocusState`) passes `focus:` and sets its state there.
- The command palette runs a command as its key would with `KeyCommandCenter.run(_:in:)` and shows its key from
  `Keybindings.chords`; what acts on the open session lives in `OpenSessionActions`, shared by the keys and the palette.
- Do not add `.keyboardShortcut` or `onKeyPress` with modifiers for something that is a command (see
  [`UI-COMPONENTS.md`](UI-COMPONENTS.md)). `KeybindingsTests` covers parsing, `when`, matching, conflicts, the file and
  the pressed-key mapping.
