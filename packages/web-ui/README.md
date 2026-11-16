# Nook's shared web interface

Svelte 5 components that every web surface of Nook uses, so they look and work the same. Today that is the
**composer**, the box you write to Nook in:

- the Tauri app for Windows, Linux and Android (`apps/tauri/src/components/Composer.svelte`)
- the browser extension's side panel (`apps/browser-extension/composer/`, built into `ui/composer.js`)

The Mac's `SessionComposer` is the specification: the text on top, under it a row with attach, the surface's own
choices, and the round send button on the right, which turns into a stop button while Nook answers.

| File | What it is |
|---|---|
| `src/Composer.svelte` | The composer. Colors come from the surface as `--nc-*` variables; parts of its own go in the `top`, `controls`, `extras` and `under` snippets |
| `src/draft.svelte.ts` | What is typed or attached but not sent yet. A surface that can read documents passes a reader; without one it takes pictures only |
| `src/recall.ts` | Up in an empty field brings back an earlier question |

There is no build of its own: the Tauri app compiles these files with its interface (an `@nook/web-ui` alias in
`vite.config.ts` and `tsconfig.json`), and `npm run build:extension` here builds the extension's composer. Svelte and
Vite are installed here for that build only (`npm ci`); keep their versions the same as in `apps/tauri`.

The Tauri app's tests cover `recall.ts` (`apps/tauri/src/lib/recall.test.ts`).
