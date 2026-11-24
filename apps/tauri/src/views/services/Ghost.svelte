<script lang="ts">
  // The ghost text of Autocomplete Anywhere: gray text right after the caret in another app, or the emoji picker card under
  // it. A click-through window that never takes the focus; the controller places it and the keyboard hook picks emoji.
  import { autocompleteEvents, type GhostEvent } from "../../lib/autocomplete";
  import { tr } from "../../lib/i18n.svelte";

  let ghost = $state<GhostEvent | null>(null);
  const ratio = typeof window === "undefined" ? 1 : window.devicePixelRatio || 1;

  $effect(() => {
    document.body.classList.add("bar");
    const un = autocompleteEvents.onGhost((e) => (ghost = e));
    return () => {
      un.then((f) => f());
    };
  });

  // The caret height is in physical pixels; the font is a little smaller than the line.
  const fontSize = $derived(ghost?.kind === "text" ? Math.max(9, (ghost.caretHeight * 0.78) / ratio) : 13);
  const selectedName = $derived(ghost?.kind === "picker" ? (ghost.choices[ghost.selected]?.name ?? "") : "");
</script>

{#if ghost?.kind === "text"}
  <div class="text" style="font-size:{fontSize}px">{ghost.text}</div>
{:else if ghost?.kind === "picker"}
  {@const l = ghost.layout}
  <div class="card" style="padding:{l.padding}px">
    <div class="grid" style="grid-template-columns:repeat({l.columns},{l.cell}px);grid-auto-rows:{l.cell}px">
      {#each ghost.choices as choice, i (i)}
        <div class="cell" class:on={i === ghost.selected}>
          <span class="emoji">{choice.emoji}</span>
          {#if Math.floor(i / l.columns) === Math.floor(ghost.selected / l.columns)}
            <span class="number">{(i % l.columns) + 1}</span>
          {/if}
        </div>
      {/each}
    </div>
    <div class="footer" style="height:{l.footer}px">
      <span>:{selectedName}</span>
      <span class="faint">{tr("Tab kiest · 1–9 · Esc", "Tab picks · 1–9 · Esc")}</span>
    </div>
  </div>
{/if}

<style>
  .text {
    color: color-mix(in srgb, var(--text3) 85%, transparent);
    white-space: pre;
    overflow: hidden;
    height: 100vh;
    display: flex;
    align-items: center;
    font-family: system-ui, "Segoe UI", sans-serif;
  }
  .card {
    box-sizing: border-box;
    height: 100vh;
    background: color-mix(in srgb, var(--graphite) 94%, transparent);
    border: 1px solid var(--line2);
    border-radius: var(--radius-panel);
    display: flex;
    flex-direction: column;
  }
  .grid { display: grid; }
  .cell { position: relative; display: flex; align-items: center; justify-content: center; border-radius: var(--radius-control); }
  .cell.on { background: color-mix(in srgb, var(--iris) 28%, transparent); }
  .emoji { font: var(--text-display); line-height: 1; }
  .number { position: absolute; right: 3px; bottom: 1px; font: var(--text-caption); color: var(--text2); }
  .footer { display: flex; justify-content: space-between; align-items: flex-end; font: var(--text-label); padding: 0 4px; }
</style>
