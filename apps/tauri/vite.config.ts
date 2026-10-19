import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

const host = process.env.TAURI_DEV_HOST;

// Tauri verwacht een vaste poort en geen schermvullende foutmeldingen van Vite.
export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host ? { protocol: "ws", host, port: 1421 } : undefined,
    watch: { ignored: ["**/src-tauri/**", "**/core/**"] },
  },
  build: { target: "es2021", sourcemap: false },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
