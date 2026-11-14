# Search Everything (macOS)

Press **⌘K** (or **⇧⌘F**) anywhere in the panel (the notch or the main window), or click the magnifying glass in the panel header,
to search all of Nook at once:

| Kind | What it searches | Opening a hit |
| --- | --- | --- |
| Nook | Your conversations with Nook: title and every message | Opens the conversation |
| Sessions | Agent sessions Nook runs (title, task, instructions, your prompts, the agent's answers, tools and changed files), the agents it follows in a terminal or editor, and every earlier session of every coding agent, the ones under **Settled** too, each with its whole conversation read from the agent's own transcript | Opens the session on the Agents tab; a session Nook runs opens with its find bar on the words that matched |
| Chats | WhatsApp (with a linked phone) and the chats collected from other apps | Opens the chat on the Chats tab |
| Notes | Recorded calls: summary, key points, to-dos and every line by speaker | Opens the note as a conversation |
| Memory | What Nook remembers | Settings › Memory |
| Notices | Nook's notice history | Whatever the notice was about |
| Settings | Every setting by its on-screen name, and by its English name | The right Settings page |
| Actions | New conversation, new session, pull requests, usage, terminals, browser, worktrees, record a call, open the window, Settings, the shortcut cheat sheet, Instructions, and the answer style of the open conversation (standard, concise, explanatory, formal, casual) | Runs it |

Everything works from the keyboard while you type: **Return** opens the chosen row (the top hit unless you moved), and
pressed before the results are in it opens the best one as soon as they arrive. **↑/↓** (or **⌃N/⌃P**) move, **⌘1–⌘9**
open the first nine rows at once, **Tab / ⇧Tab** step through the kinds, **Escape** clears and then closes.

Everything stays on the Mac: search reads Nook's own local data and never sends anything to a brain. A last row offers
**Ask Nook** with what you typed, through the normal chat pipeline.

## Query language

Plain words must all match. Matching ignores case and accents, accepts the start of a word (`dinn` finds *dinner*),
a part of a word, and typos (one in a word of 4–6 letters, two in a longer one).

| Syntax | Meaning |
| --- | --- |
| `"exact words"` | The words in this order |
| `-word`, `-"some words"` | Leave out what contains it |
| `a OR b`, `a \| b` | Either one |
| `in:agents`, `in:chats`, `in:nook`, `in:notes`, `in:memory`, `in:notices`, `in:settings`, `in:actions` | Only that kind (a unique start such as `in:sess` works too, and the Dutch, German, French and Spanish names); `-in:` leaves one out |
| `from:me`, `from:nook`, `from:anna`, `from:"Anna de Vries"`, `from:claude` | Only what that person, Nook or agent wrote; the title no longer counts |
| `app:telegram`, `project:nook`, `branch:main`, `agent:codex`, `speaker:anna`, `type:fact` | A named property of the hit |
| `is:unread`, `is:pinned`, `is:archived`, `is:running`, `is:failed`, `is:waiting`, `is:done`, `is:settled` (`is:afgehandeld`), `is:group` | A state; `-is:` inverts |
| `after:2026-10-01`, `before:7d`, `on:yesterday`, `date:week` | Dates: `today`, `yesterday`, `week`, `month`, `year`, `3h`, `7d`, `2w`, `6m`, `1y`, `2026-10-01`, `2026-10`, `2026` |
| `/regex/` | A regular expression, ignoring case |

A query of only filters (`in:chats is:unread`) lists everything that passes them, newest first.

## Ranking

Results are ranked like BM25: a rare word weighs more than a common one, and a word that repeats counts less each time.
A match in the title weighs three times as much as one in the text, a whole query in the title, every word in one message
(which then is the snippet) or the words side by side add a bonus, and a document from today scores up to a third more, fading over a couple of weeks. The best hit is shown on
top; the rest are grouped by kind, and a chip (or Tab) keeps one kind.

## Code

| Part | File |
| --- | --- |
| Query parser, index, ranking, snippets and highlighting (Foundation-only, tested in `NookSearchTests`) | `apps/macos/Services/Search/NookSearch.swift` |
| Background indexing and debounced searching; session transcripts and the agents' own transcript files read from disk once (again only when they change) and kept, the index filling in as they are read | `apps/macos/Services/Search/SearchCenter.swift` |
| What is searched and where a hit opens | `apps/macos/App/AppModel+Search.swift` |
| The panel | `apps/macos/UI/Pills/SearchPanel.swift` |

## Deep links

`nook://` links open places inside Nook (`NookDeepLink`, `apps/macos/Services/Workspace/NookDeepLink.swift`):
`nook://conversation/<uuid>` (a Nook conversation), `nook://settings/<page>` (a Settings page by its id, e.g. `memory`,
`shortcuts`, `instructions`), `nook://memory` and `nook://shortcuts` (the cheat sheet). A link only names a place; an id
that is not a UUID or a page that does not exist opens nothing. `nook://session/…` and `nook://prompt?…` keep their own
links (`SessionLink`, `PromptLink`).
