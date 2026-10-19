<script lang="ts">
  // Eén terminal, getekend met xterm.js. De shell zelf draait in Rust (portable-pty) en blijft leven als dit
  // onderdeel verdwijnt; bij terugkomen wordt de bewaarde uitvoer opnieuw getoond.
  import { FitAddon } from "@xterm/addon-fit";
  import { Terminal } from "@xterm/xterm";
  import "@xterm/xterm/css/xterm.css";
  import { toolEvents, toolsApi } from "../../lib/workspace/api";

  let { id }: { id: string } = $props();
  let host = $state<HTMLDivElement>();

  $effect(() => {
    if (!host) return;
    const term = new Terminal({
      fontFamily: getComputedStyle(document.documentElement).getPropertyValue("--mono") || "monospace",
      fontSize: 12.5,
      cursorBlink: true,
      scrollback: 5000,
      theme: { background: "#0b0a12", foreground: "#f4f3f7", cursor: "#f4f3f7", selectionBackground: "#3a3a48" },
      allowProposedApi: false,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host);
    let disposed = false;
    let unlisten: (() => void) | null = null;
    toolsApi.replay(id).then((text) => {
      if (disposed) return;
      term.write(text);
      toolEvents.onOutput((c) => c.id === id && term.write(c.data)).then((u) => (disposed ? u() : (unlisten = u)));
    });
    const input = term.onData((data) => toolsApi.write(id, data).catch(() => {}));
    const resize = () => {
      try {
        fit.fit();
        toolsApi.resize(id, term.cols, term.rows).catch(() => {});
      } catch {
        // Nog niet zichtbaar.
      }
    };
    const observer = new ResizeObserver(resize);
    observer.observe(host);
    requestAnimationFrame(() => {
      resize();
      term.focus();
    });
    return () => {
      disposed = true;
      observer.disconnect();
      input.dispose();
      unlisten?.();
      term.dispose();
    };
  });
</script>

<div class="term" bind:this={host}></div>

<style>
  .term { flex: 1; min-height: 0; width: 100%; background: #0b0a12; border-radius: 10px; padding: 6px; box-sizing: border-box; }
  .term :global(.xterm) { height: 100%; }
</style>
