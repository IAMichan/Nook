# Nook's shared web interface

Svelte 5 components that every web surface of Nook uses, so they look and work the same: the **composer** (the box
you write to Nook in), its **model chip**, the **transcript** of a conversation with Nook, and the **Markdown** renderer
for answers. The composer is used by:

- the Tauri app for Windows, Linux and Android (`apps/tauri/src/components/Composer.svelte`)
- the browser extension's side panel (`apps/browser-extension/composer/`, built into `ui/composer.js`)

The Mac's `SessionComposer` is the specification: the text on top, under it a row with attach, the surface's own
choices, and the round send button on the right, which turns into a stop button while Nook answers.

| File | What it is |
|---|---|
| `src/Composer.svelte` | The composer. Colors come from the surface as `--nc-*` variables; parts of its own go in the `top`, `controls`, `extras` and `under` snippets |
| `src/draft.svelte.ts` | What is typed or attached but not sent yet. A surface that can read documents passes a reader; without one it takes pictures only |
| `src/recall.ts` | Up in an empty field brings back an earlier question |
| `src/ModelPicker.svelte` | The model chip for the composer's row, as the Mac's `BrainChip` and `ModelPicker`: the agent's logo and model, and a panel with a rail of places (this Mac first, then the agents) and the shown place's models with a search. Colors are the composer's `--nc-*` |
| `src/AgentMark.svelte`, `src/brands.ts` | An agent's or model's mark as the Mac's `AgentLogo` and `BrandMark` draw it |
| `src/brandLogos.ts` | The brand marks as SVG paths, generated from the Mac's `BrandLogo.swift` by `node scripts/brand-logos.mjs` |
| `src/Transcript.svelte` | A conversation as Nook Chat on the Mac draws it: questions in bubbles, answers as Markdown, the plan as a checklist, where Nook looked, and what it does now. Colors come as `--nt-*` variables. Used by the browser extension's side panel |
| `src/markdown.ts` | The safe Markdown renderer for answers (everything escaped first). The Tauri app (`src/lib/markdown.ts`) and the transcript use it |

There is no build of its own: the Tauri app compiles these files with its interface (an `@nook/web-ui` alias in
`vite.config.ts` and `tsconfig.json`), and `npm run build:extension` here builds the extension's composer. Svelte and
Vite are installed here for that build only (`npm ci`); keep their versions the same as in `apps/tauri`.

The Tauri app's tests cover `recall.ts` and `markdown.ts` (`apps/tauri/src/lib/recall.test.ts`, `markdown.test.ts`).
