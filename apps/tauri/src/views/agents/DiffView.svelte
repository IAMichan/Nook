<script lang="ts">
  // Een diff van een wijziging: groen erbij, rood eraf, grijs context, with a +/− marker column and the changed part of
  // an edited line highlighted, like the diff view of a session's changes.
  import type { DiffLine } from "../../lib/agents";
  import { lineRows } from "../../lib/workspace/unifiedDiff";

  let { lines, max = 0 }: { lines: DiffLine[]; max?: number } = $props();
  const rows = $derived(lineRows(lines));
</script>

<div class="diff" style={max ? `max-height:${max}px` : ""}>
  {#each rows as row, i (i)}
    <div class="line {row.kind}"><span class="marker">{row.kind === "add" ? "+" : row.kind === "remove" ? "−" : ""}</span><span class="code">{#if row.changed}{row.text.slice(0, row.changed[0])}<mark>{row.text.slice(row.changed[0], row.changed[1])}</mark>{row.text.slice(row.changed[1])}{:else}{row.text || " "}{/if}</span></div>
  {/each}
</div>

<style>
  .diff {
    margin: 0;
    font-family: var(--mono);
    font-size: 11.5px;
    line-height: 1.45;
    background: var(--field);
    border: 1px solid var(--line2);
    border-radius: 10px;
    padding: 6px 0;
    overflow: auto;
    user-select: text;
  }
  .line { display: grid; grid-template-columns: 18px 1fr; padding-right: 10px; }
  .marker { text-align: center; font-weight: 600; user-select: none; }
  .code { white-space: pre-wrap; word-break: break-word; }
  .context .code { color: var(--text3); }
  .add { background: color-mix(in srgb, var(--mint) 8%, transparent); }
  .add .marker, .add .code { color: var(--mint); }
  .add mark { background: color-mix(in srgb, var(--mint) 30%, transparent); color: inherit; border-radius: 2px; }
  .remove { background: color-mix(in srgb, var(--coral) 8%, transparent); }
  .remove .marker, .remove .code { color: var(--coral); }
  .remove mark { background: color-mix(in srgb, var(--coral) 30%, transparent); color: inherit; border-radius: 2px; }
</style>
