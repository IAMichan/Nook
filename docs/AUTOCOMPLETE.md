# Autocomplete Anywhere

While you type in any macOS app, Nook suggests how your sentence continues as inline gray ghost text right after your cursor—powered by a local model on your Mac. Press **Tab** to accept the next word, or **⇧Tab** to accept the entire suggestion. If you keep typing matching characters, the ghost text advances smoothly; any other key dismisses it immediately.

Enable it in **Settings › Autocomplete**, which has five tabs:

- **General:** On/off toggle and live status, model selection (your Brain model, a local GGUF model on your Mac, a custom `.gguf` file, or a one-click download), suggestion length and eagerness, and customizable shortcuts.
- **Apps:** Every installed app with its icon and toggle. Search or filter by Enabled/Disabled. Click any app for custom per-app instructions, whether to leave `Tab` to the app, mid-line suggestions, learning, font size, vertical offset, or pausing. Below the app list, configure per-website rules and instructions inside browsers. Terminals, code editors, and password managers are disabled by default.
- **Style & Context:** What context the model receives (active app and window title, Nook memory, screen text, clipboard), your writing style and local learning, emoji shortcodes, typo correction, battery behavior, and alternative word suggestions.
- **Playground:** A text box to try autocomplete without leaving Settings. It uses the same model, accept keys, and suggestion settings as other apps (your instructions and memory included; screen, window, and clipboard are left out), and shows the model's raw answer, what was shown, how long it took, and the full prompt the model read. Nothing typed there is saved or counted in the statistics.
- **Statistics:** Usage counts for today, this week, and all time, a 30-day chart, estimated typing time saved, characters completed, acceptance rate, daily streak, and top apps. Nook only records aggregate counts—never what you typed.

## Key Features

- Inline ghost text in any app. **Tab** accepts one word, **⇧Tab** accepts the full completion, or just keep typing. All shortcuts are customizable.
- 100% local inference on your Mac: uses either your built-in MLX brain model or a GGUF model via `llama.cpp` (Metal-accelerated). No word limits and no subscription.
- Custom instructions globally, per app, and per website.
- Optional context from your Nook memory, active screen text (e.g., the email you are replying to), and clipboard.
- Mid-line completions, an emoji picker (type `:` and pick by arrow keys, number or click, or type on to search: `:smile`, `:duim`), inline typo fixes, and numbered word alternatives.
- Optionally, the number of words completed today next to Nook's icon in the menu bar.
- Learns from your own writing locally while automatically filtering out secrets, API keys, and national ID numbers.
- Respects macOS smart quotes and can shorten or pause completions on battery power.

## How It Works

1. **Key event filter (`CGEventTap`).** Observes keystrokes before the target app. Only acceptance keys are intercepted, and only while a suggestion is actively displayed.
2. **Reading the focused field (`AutocompleteField`).** After a brief debounce (40 ms by default), Nook reads the focused text field via the macOS Accessibility API: text before and after the cursor, selection, cursor bounds, placeholder, window title, and browser URL. For Chromium, Electron, and WebKit apps, it uses text markers and `AXManualAccessibility` / `AXEnhancedUserInterface`. Password fields (`AXSecureTextField`) and Secure Event Input mode are strictly ignored.
3. **Choosing the completion source.** Typing `:` at the start of a word opens the emoji picker; a misspelled preceding word offers a typo correction; otherwise, the local language model generates a continuation.
4. **Prompt construction (`PromptBuilder`).** Assembles a structured prompt containing your instructions and Nook memory, writing samples, screen context, clipboard, target app/site metadata, and the text preceding your cursor, as two parts: the context (fixed per field) and the text (`CompletionPrompt`). The prompt window slides in 500–1,000 character increments so the model's KV cache is reused across keystrokes.
   - **Base models** read it as a document: the context as a header, then your text.
   - **Chat (instruction-tuned) models** read it in their own chat template (`CompletionChat`): the context and the task ("continue the text I am typing, in its language and style") go in the user's turn, and the model's answer starts with the text you typed, which it simply goes on with. Fed a bare document, a chat model tends to answer the text or drift into the headers instead. This applies to the brain's MLX models and to any GGUF model with a chat template that is not a base model. Text that reads as a control token (`<|im_end|>`, `<end_of_turn>`) is taken out of the context, so screen text cannot end the user's turn.
5. **Model inference (`LlamaCompleter` / `BrainCompleter`).** Runs `llama.cpp` (via `LlamaSwift`) or `mlx-swift-lm` on Metal. A certainty threshold filters out low-confidence starts and stops generation as soon as token confidence drops. Words you frequently write receive a small logit bonus.
6. **Rendering & typing (`GhostOverlay` & `AutocompleteTyper`).** Draws the suggestion in a click-through, non-activating overlay panel matching the host app's font and size (`AXAttributedStringForRange`). Accepted words are injected as Unicode key events so your clipboard is never touched.

## Speed

- **Word by word:** each word is shown as soon as the model has finished it, while the rest is still being written.
- **Fixed context per field:** everything before your text in the prompt is gathered once per field, so a key only costs the last few tokens.
- **Writing ahead:** while a suggestion is on screen, Nook already writes how the text goes on after it. Taking the last word shows that next suggestion at once, moved past the word just typed, before the app has even drawn it (`settle()` then lines it up with the real cursor); typing it to the end shows it as soon as the app has the text. A suggestion taken while it is still being written starts the writing ahead right away, from what is on screen.
- **Chains do not stall:** every suggestion ends where the model got unsure, so the next one starts at an unsure point. Suggestions right after one that was taken whole use lower thresholds (`CompletionOptions.continuing()`), so Tab, Tab, Tab keeps going instead of stopping after two or three suggestions.
- **Window text without blocking:** with "What is on your screen" on (the default), the text of the window you write in comes from Nook's screen reading when that is on, and otherwise autocomplete reads the focused window itself through Accessibility (`AppTextReader.focusedWindowText`), once per field and off the main thread. The first suggestion in a field does not wait for it.

## Quality

- **Token healing (GGUF):** with the cursor in the middle of a word, the prompt is read without that word, and the model has to spell it again from the tokens that fit it (`CompletionHealing`). A cut-off word like "morg" tokenizes unlike anything the model learned from. While you type the rest of the word, the prompt stays the same, so it is faster too.
- **Sure of the whole suggestion:** besides the threshold per token, the product of all token probabilities must stay above a threshold (`minSequenceProbability`), so a suggestion ends where it starts to drift. "Eagerness" sets all thresholds.
- **No half words:** when the model stops because it is no longer sure, it stops at the last whole word.
- **No copies:** three words or more that already stand in the last lines before the cursor are not shown.
- **Screen text without the interface:** only lines that read as text go into the prompt (four words or more, or a short sentence such as "Kom je morgen?"), not buttons, labels and menus.
- **The text you reply to:** autocomplete reads the pane around the field (`AppTextReader.textAroundFocus`: the nearest ancestor of the focused element with enough text, such as the conversation above a message field) instead of the whole window with its sidebar first. The prompt keeps the *end* of it (`CompletionScreenText.recent`), so the newest messages sit right above your text. Nook's own screen reading fills in until that read is done.
- **Fresh context:** the context around a field is gathered again after a message is sent (the field empties) and every three minutes, so new incoming messages are seen. The clipboard only goes into the prompt for five minutes after it was copied.
- **Typo check:** the last finished word is checked with the macOS spell checker, also while the next word is being typed (the fix then retypes that word's start too). Short or mixed-language text is checked in the likely languages and the ones set in macOS, and only counts as a typo when none of them knows the word. The fix comes from the autocorrect choice or the spell checker's guesses, but only when it is one or two letters away (`CompletionTextAnalysis.isLikelyFix`). Words you write often, and fixes turned down with Escape, are left alone.
- **Chat models first:** automatic model choice prefers a chat (instruct) model, then a base model, and a code or math model last. Measured with Gemma 4 E4B on eight everyday messages (Dutch and English, with and without screen context): the instruct model made a suggestion for all eight, sure of its first word 36–98% of the time; the base model of the same size made one for only two, mostly too unsure (6–28%) to show anything. Settings recommends Gemma 4 E4B Instruct from 24 GB of memory and E2B Instruct from 16 GB.

## Emoji Picker

Typing `:` at the start of a word opens a picker under the cursor: the emoji you used last, then the most used. Typing on (`:lach`, `:heart`) filters it at once, without reading the field again. Pick with the arrow keys and Tab (or Return, once two letters are typed, so `:D` and Return still sends), with 1–9 for the row with the selection, or with a click: the panel itself takes no clicks, so the key tap hit-tests the card on a mouse down and swallows that click. Escape, a space or punctuation closes it.

## Model Selection

In **Automatic** mode, Nook selects a model in this order:

1. **An existing GGUF model already on your Mac.** `CompletionModelLocator` scans `~/Library/Application Support`, `~/Library/Caches`, LM Studio's models folder, and Hugging Face / `llama.cpp` caches (skipping vision projectors, embedding models, and files under 50 MB) without copying or modifying the file.
2. **A GGUF model downloaded in Settings.** Under **Settings › Autocomplete › General › Download GGUF models**, you can download recommended base models or the Gemma 4 E2B/E4B instruct (chat) models with live progress, or paste any Hugging Face `.gguf` URL.
3. **Your local Brain model.** Reuses Nook's built-in MLX model (`BrainCompleter`) with KV-cache checkpointing so no extra model download is needed. Whenever the chat brain is actively generating a reply, autocomplete yields automatically.

## Building & Testing

The `LlamaSwift` package ([mattt/llama.swift](https://github.com/mattt/llama.swift), pinned to `2.10549.0` / `llama.cpp` `b10549`) is configured in `apps/macos/project.yml`. Run `xcodegen` in `apps/macos` after pulling changes.

Foundation-only autocomplete logic is tested in `apps/macos/Tests/NookTests/AutocompleteTests.swift` (`GGUFReader`, `CompletionModels`, `CompletionSuggestion`, `CompletionPreferences`, `CompletionEmoji`, `CompletionPrivacy`, and `CompletionLearning`) and runs via `./scripts/core-tests.sh --filter AutocompleteTests`.
