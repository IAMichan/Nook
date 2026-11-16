// Builds the browser extension's composer (apps/browser-extension/composer, on the shared one in src/) into
// apps/browser-extension/ui/composer.js: one readable ES module with its styles inside, loaded by sidepanel.js. The
// result is checked in, so the Mac app carries a working extension without a build step of its own, and the
// extension's folder holds no node_modules (the Mac app copies all of it). CI fails when it is not up to date.
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { fileURLToPath } from 'node:url';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const extension = here('../../apps/browser-extension/');

export default defineConfig({
  root: here('.'),
  plugins: [svelte({ compilerOptions: { css: 'injected' } })],
  // Svelte is installed here only: imports of it from the extension's files resolve to this copy.
  resolve: { alias: { '@nook/web-ui': here('src') }, dedupe: ['svelte'] },
  build: {
    outDir: extension + 'ui',
    emptyOutDir: true,
    target: 'chrome116',
    // Readable for the Chrome Web Store's review, and small enough as it is.
    minify: false,
    sourcemap: false,
    lib: { entry: extension + 'composer/main.svelte.js', formats: ['es'], fileName: () => 'composer.js' }
  },
  logLevel: 'warn'
});
