# Search Everything (macOS)

Press **⌘K** (or **⇧⌘F**) anywhere in the panel (the notch or the main window), or click the magnifying glass in the panel header,
to search all of Nook at once:

| Kind | What it searches | Opening a hit |
| --- | --- | --- |
| Nook | Your conversations with Nook: title and every message | Opens the conversation |
| Sessions | Agent sessions Nook runs (title, task, instructions, your prompts, the agent's answers, tools and changed files) and the agents it follows in a terminal or editor | Opens the session on the Agents tab, with its find bar on the words that matched |
| Chats | WhatsApp (with a linked phone) and the chats collected from other apps | Opens the chat on the Chats tab |
| Notes | Recorded calls: summary, key points, to-dos and every line by speaker | Opens the note as a conversation |
| Memory | What Nook remembers | Settings › Memory |
| Notices | Nook's notice history | Whatever the notice was about |
| Settings | Every setting by its on-screen name, and by its English name | The right Settings page |
| Actions | New conversation, new session, pull requests, usage, terminals, browser, worktrees, record a call, open the window, Settings | Runs it |

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
| `is:unread`, `is:pinned`, `is:archived`, `is:running`, `is:failed`, `is:waiting`, `is:done`, `is:group` | A state; `-is:` inverts |
| `after:2026-10-01`, `before:7d`, `on:yesterday`, `date:week` | Dates: `today`, `yesterday`, `week`, `month`, `year`, `3h`, `7d`, `2w`, `6m`, `1y`, `2026-10-01`, `2026-10`, `2026` |
| `/regex/` | A regular expression, ignoring case |

A query of only filters (`in:chats is:unread`) lists everything that passes them, newest first.

## Ranking

Results are ranked like BM25: a rare word weighs more than a common one, and a word that repeats counts less each time.
A match in the title weighs three times as much as one in the text, a whole query in the title or the words side by side
add a bonus, and a document from today scores up to a third more, fading over a couple of weeks. The best hit is shown on
top; the rest are grouped by kind, and a chip (or Tab) keeps one kind.

## Code

| Part | File |
| --- | --- |
| Query parser, index, ranking, snippets and highlighting (Foundation-only, tested in `NookSearchTests`) | `apps/macos/Services/Search/NookSearch.swift` |
| Background indexing and debounced searching; session transcripts read from disk once and kept | `apps/macos/Services/Search/SearchCenter.swift` |
| What is searched and where a hit opens | `apps/macos/App/AppModel+Search.swift` |
| The panel | `apps/macos/NotchUI/Pills/SearchPanel.swift` |
