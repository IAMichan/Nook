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
    const MIN_HOST_WIDTH = 100;
    const MIN_HOST_HEIGHT = 40;
    let disposed = false;
    let ready = false;
    let unlisten: (() => void) | null = null;
    const input = term.onData((data) => toolsApi.write(id, data).catch(() => {}));
    const resize = () => {
      if (!host || !ready) return;
      // A container still laying out can briefly measure a few pixels wide; don't start or resize a shell to that.
      if (host.clientWidth < MIN_HOST_WIDTH || host.clientHeight < MIN_HOST_HEIGHT) return;
      try {
        fit.fit();
        if (term.cols >= 10 && term.rows >= 2) {
          toolsApi.resize(id, term.cols, term.rows).catch(() => {});
        }
      } catch {
        // Not visible yet.
      }
    };
    const observer = new ResizeObserver(resize);
    observer.observe(host);
    // Attach the output stream and replay buffered bytes before sending the initial fitted size,
    // so a shell that starts on the first `resize` never loses its earliest output.
    toolsApi
      .replay(id)
      .catch(() => "")
      .then((text) => {
        if (disposed) return;
        if (text) term.write(text);
        return toolEvents.onOutput((c) => c.id === id && term.write(c.data)).then((u) => {
          if (disposed) {
            u();
            return;
          }
          unlisten = u;
          ready = true;
          requestAnimationFrame(() => {
            if (disposed) return;
            resize();
            term.focus();
          });
        });
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
