import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { fileURLToPath } from "node:url";

// Nook's shared web interface (packages/web-ui): the composer the browser extension uses too.
const webUi = fileURLToPath(new URL("../../packages/web-ui/src", import.meta.url));

const host = process.env.TAURI_DEV_HOST;

// Tauri verwacht een vaste poort en geen schermvullende foutmeldingen van Vite.
export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  // The shared package has no node_modules of its own: its imports of Svelte resolve to this app's copy.
  resolve: { alias: { "@nook/web-ui": webUi }, dedupe: ["svelte"] },
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host ? { protocol: "ws", host, port: 1421 } : undefined,
    watch: { ignored: ["**/src-tauri/**", "**/core/**"] },
    fs: { allow: [".", webUi] },
  },
  build: { target: "es2021", sourcemap: false },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
