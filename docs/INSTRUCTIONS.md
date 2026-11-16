# Instructions, spaces and the context inspector (macOS)

Settings › **Instructions** (`InstructionsSettingsSection`) holds what shapes every answer besides the question itself.

| Part | What it does | Code |
| --- | --- | --- |
| Answer style | Standard, concise, explanatory, formal or casual: one line of instructions added to the context. The default is set in Settings; each conversation picks its own with the ⌘K actions "Answer style: …". Only voice and length change, never facts or sources | `Brain/ResponseStyle.swift` (`ResponseStyle`, `ResponseStyleStore`) |
| Saved prompts | A title, a body with `{{variables}}` (`{{topic}}`, `{{tone|friendly}}`) and an optional trigger. Foundation-only: parsing, rendering, trigger and search matching, JSON | `Services/Workspace/PromptLibrary.swift` |
| Spaces | Instructions (and attached paths) for every Nook conversation filed in a space. Not a coding project (a folder an agent works in) | `Services/Workspace/NookSpace.swift` |
| Context inspector | The parts of the last answer's context (style, space, memory, looked up, overview) with an estimated token count and the share of the model's window | `Brain/ContextBreakdown.swift`, `App/AppModel+ContextInspector.swift` |
| Memory | Lives in Settings › Memory: each item shows its source and date, can be edited, pinned, kept on this Mac, or forgotten | `App/Settings/SettingsView+Memory.swift` |

Style and space instructions reach the model through the one chat pipeline (`AppModel.answer`), after `prepareRun`, so
every brain gets them the same way. They are stored in `prompts.json`, `spaces.json` and the user defaults on this Mac;
nothing is sent anywhere except as part of the context the chosen brain reads, which the inspector shows.

Not built yet: a composer picker for saved prompts (the `/trigger` list), a conversation-header menu for spaces and
styles, and attaching files to a space (the path list exists in the model).
