# Third-Party Notices

Parts of Nook (marked `"see THIRD-PARTY-NOTICES.md"` in the source files, including Flow dictation, Call Notetaker, WhatsApp helpers, `EnergyVAD`, `Fuzzy`, and `ScreenPart`) are adapted from open-source code under the MIT License:

```text
MIT License

Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Parakeet speech recognition and speaker diarization use [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).

---

## Autocomplete Anywhere

Autocomplete runs GGUF models with [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT, © 2023–2026 The ggml authors), through the [llama.swift](https://github.com/mattt/llama.swift) package (MIT, © Mattt).

Parts of its design and code (the suggestion, prompt and policy logic, the llama.cpp engine with its certainty threshold and word bonus, the accessibility reader with text markers, the overlay, the emoji table, the secret filter, writing samples and statistics, and the model catalog) are adapted from [Typist](https://github.com/BrodySalvucci/Typist):

```text
MIT License

Copyright (c) 2026 Brody Salvucci

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Provider & Brand Icons

Vector icon paths in `apps/macos/NotchUI/Components/BrandLogo.swift` are adapted from the open-source [LobeHub Icons (`@lobehub/icons`)](https://github.com/lobehub/lobe-icons) set:

```text
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

All third-party brand names and logos are trademarks of their respective owners and are used solely to identify user-configured integrations and AI providers.

---

## Swift Package Dependencies

Nook uses the following open-source Swift packages:

- **mlx-swift** & **mlx-swift-lm** — MIT License (© Apple Inc.)
- **swift-transformers**, **swift-huggingface**, **swift-jinja** — Apache License 2.0 (© Hugging Face)
- **swift-argument-parser**, **swift-asn1**, **swift-collections**, **swift-crypto**, **swift-numerics**, **swift-syntax** — Apache License 2.0 (© Apple Inc.)
- **FluidAudio** — Apache License 2.0 (© FluidInference)
- **llama.swift** / **llama.cpp** — MIT License (© Mattt / The ggml authors)
- **SwiftTerm** — MIT License (© Miguel de Icaza)
- **EventSource** — MIT License (© Recouse)
- **yyjson** — MIT License (© YaoYuan)

---

## Optional Downloaded Models & External Runtimes

Nook does not bundle any AI model weights or proprietary agent binaries in this repository. When you choose to download local MLX/GGUF models (from Hugging Face) or connect external coding-agent CLIs (such as Claude Code, Codex, Gemini CLI, or Google Antigravity's ACP server), those downloads and tools are governed by their respective licenses and terms of use (for example, the [Google Gemma Terms of Use](https://ai.google.dev/gemma/terms), the [Meta Llama Community License](https://www.llama.com/llama3_1/license/), and the Apache-2.0 / Qwen licenses).
