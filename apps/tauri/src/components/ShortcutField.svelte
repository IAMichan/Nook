<script lang="ts">
  // A global shortcut you set by pressing it: click, press the keys, done. Escape cancels, Backspace turns it off.
  // No more typing "Alt+CommandOrControl+Space" by hand.
  import { readableShortcut, recordShortcut } from "../lib/accelerator";

  let { value, taken = false, onchange }: { value: string; taken?: boolean; onchange: (accelerator: string) => void } = $props();
  let recording = $state(false);
  let hint = $state<string | null>(null);

  function keydown(e: KeyboardEvent) {
    if (!recording) return;
    e.preventDefault();
    e.stopPropagation();
    const result = recordShortcut(e);
    switch (result.kind) {
      case "waiting": return;
      case "cancel": return stop();
      case "clear": onchange(""); return stop();
      case "invalid": hint = result.reason; return;
      case "done": onchange(result.accelerator); return stop();
    }
  }

  function stop() {
    recording = false;
    hint = null;
  }
</script>

<span class="field">
  <button
    type="button"
    class="shortcut"
    class:recording
    class:taken
    onclick={() => { recording = !recording; hint = null; }}
    onkeydown={keydown}
    onblur={stop}
    aria-label={recording ? "Druk nu de nieuwe toetsen in" : `Sneltoets ${readableShortcut(value)}, klik om te wijzigen`}
  >{recording ? "Druk de toetsen in…" : readableShortcut(value)}</button>
  {#if recording}<small class="faint">{hint ?? "Esc annuleert · Backspace zet uit"}</small>
  {:else if taken}<small class="taken-note">Bezet door een andere app — kies een andere</small>{/if}
</span>

<style>
  .field { display: flex; flex-direction: column; align-items: flex-end; gap: 2px; }
  .shortcut { min-width: 150px; font-family: var(--mono, ui-monospace, monospace); font-size: 12px; padding: 5px 10px; }
  .shortcut.recording { border-color: var(--iris); color: var(--paper); }
  .shortcut.taken { border-color: color-mix(in srgb, var(--amber) 60%, var(--line2)); }
  small { font-size: 10.5px; }
  .taken-note { color: var(--amber); }
</style>
