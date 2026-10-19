# Autocomplete Anywhere

While you type in any macOS app, Nook suggests how your sentence continues as inline gray ghost text right after your cursor—powered by a local model on your Mac. Press **Tab** to accept the next word, or **⇧Tab** to accept the entire suggestion. If you keep typing matching characters, the ghost text advances smoothly; any other key dismisses it immediately.

Enable it in **Settings › Autocomplete**, which has four tabs:

- **General:** On/off toggle and live status, model selection (your Brain model, a local GGUF model on your Mac, a custom `.gguf` file, or a one-click download), suggestion length and eagerness, and customizable shortcuts.
- **Apps:** Every installed app with its icon and toggle. Search or filter by Enabled/Disabled. Click any app for custom per-app instructions, whether to leave `Tab` to the app, mid-line suggestions, learning, font size, vertical offset, or pausing. Below the app list, configure per-website rules and instructions inside browsers. Terminals, code editors, and password managers are disabled by default.
- **Style & Context:** What context the model receives (active app and window title, Nook memory, screen text, clipboard), your writing style and local learning, emoji shortcodes, typo correction, battery behavior, and alternative word suggestions.
- **Statistics:** Usage counts for today, this week, and all time, a 30-day chart, estimated typing time saved, characters completed, acceptance rate, daily streak, and top apps. Nook only records aggregate counts—never what you typed.

## Key Features

- Inline ghost text in any app. **Tab** accepts one word, **⇧Tab** accepts the full completion, or just keep typing. All shortcuts are customizable.
- 100% local inference on your Mac: uses either your built-in MLX brain model or a GGUF model via `llama.cpp` (Metal-accelerated). No word limits and no subscription.
- Custom instructions globally, per app, and per website.
- Optional context from your Nook memory, active screen text (e.g., the email you are replying to), and clipboard.
- Mid-line completions, emoji shortcodes (`:smile`, `:thumbsup`), inline typo fixes, and numbered word alternatives.
- Learns from your own writing locally while automatically filtering out secrets, API keys, and national ID numbers.
- Respects macOS smart quotes and can shorten or pause completions on battery power.

## How It Works

1. **Key event filter (`CGEventTap`).** Observes keystrokes before the target app. Only acceptance keys are intercepted, and only while a suggestion is actively displayed.
2. **Reading the focused field (`AutocompleteField`).** After a brief debounce (120 ms by default, 70 ms while actively typing), Nook reads the focused text field via the macOS Accessibility API: text before and after the cursor, selection, cursor bounds, placeholder, window title, and browser URL. For Chromium, Electron, and WebKit apps, it uses text markers and `AXManualAccessibility` / `AXEnhancedUserInterface`. Password fields (`AXSecureTextField`) and Secure Event Input mode are strictly ignored.
3. **Choosing the completion source.** Typing `:shortcode` triggers emoji completion; a misspelled preceding word offers a typo correction; otherwise, the local language model generates a continuation.
4. **Prompt construction (`PromptBuilder`).** Assembles a structured prompt containing your instructions and Nook memory, writing samples, screen context, clipboard, target app/site metadata, and the text preceding your cursor. The prompt window slides in 500–1,000 character increments so the model's KV cache is reused across keystrokes.
5. **Model inference (`LlamaCompleter` / `BrainCompleter`).** Runs `llama.cpp` (via `LlamaSwift`) or `mlx-swift-lm` on Metal. A certainty threshold filters out low-confidence starts and stops generation as soon as token confidence drops. Words you frequently write receive a small logit bonus.
6. **Rendering & typing (`GhostOverlay` & `AutocompleteTyper`).** Draws the suggestion in a click-through, non-activating overlay panel matching the host app's font and size (`AXAttributedStringForRange`). Accepted words are injected as Unicode key events so your clipboard is never touched.

## Model Selection

In **Automatic** mode, Nook selects a model in this order:

1. **An existing GGUF model already on your Mac.** `CompletionModelLocator` scans `~/Library/Application Support`, `~/Library/Caches`, LM Studio's models folder, and Hugging Face / `llama.cpp` caches (skipping vision projectors, embedding models, and files under 50 MB) without copying or modifying the file.
2. **A GGUF model downloaded in Settings.** Under **Settings › Autocomplete › General › Download GGUF models**, you can download recommended base models with live progress or paste any Hugging Face `.gguf` URL.
3. **Your local Brain model.** Reuses Nook's built-in MLX model (`BrainCompleter`) with KV-cache checkpointing so no extra model download is needed. Whenever the chat brain is actively generating a reply, autocomplete yields automatically.

## Building & Testing

The `LlamaSwift` package ([mattt/llama.swift](https://github.com/mattt/llama.swift), pinned to `2.10549.0` / `llama.cpp` `b10549`) is configured in `apps/macos/project.yml`. Run `xcodegen` in `apps/macos` after pulling changes.

Foundation-only autocomplete logic is tested in `apps/macos/Tests/NookTests/AutocompleteTests.swift` (`GGUFReader`, `CompletionModels`, `CompletionSuggestion`, `CompletionPreferences`, `CompletionEmoji`, `CompletionPrivacy`, and `CompletionLearning`) and runs via `./scripts/core-tests.sh --filter AutocompleteTests`.

Parts of the autocomplete design and implementation are adapted from [Typist](https://github.com/BrodySalvucci/Typist) (MIT License); see [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md).
