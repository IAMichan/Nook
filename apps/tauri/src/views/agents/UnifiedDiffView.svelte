<script lang="ts">
  // A unified diff as a code review shows it (DiffText on the Mac): line numbers of the old and new file in a gutter,
  // hunks as separators with their section name, added and removed lines tinted, and the changed words of an edited
  // line highlighted. Long lines wrap instead of scrolling sideways, which suits the side panel.
  import { diffRows, hunkLabel, type DiffRow } from "../../lib/workspace/unifiedDiff";

  let { diff }: { diff: string } = $props();
  const rows = $derived(diffRows(diff));
  // Width of one line-number column, from the largest number in the diff.
  const digits = $derived(Math.max(2, String(rows.reduce((m, r) => Math.max(m, r.old ?? 0, r.new ?? 0), 0)).length));

  function parts(row: DiffRow): [string, string, string] | null {
    if (!row.changed) return null;
    const [start, end] = row.changed;
    return [row.text.slice(0, start), row.text.slice(start, end), row.text.slice(end)];
  }
</script>

<div class="udiff" style="--digits:{digits}">
  {#each rows as row, i (i)}
    {#if row.kind === "file"}
      <div class="file" class:first={i === 0}>{row.text}</div>
    {:else if row.kind === "hunk"}
      <div class="hunk">
        <span class="gutter2">↕</span><span class="hlabel">{hunkLabel(row.raw)}</span>{#if row.text}<span class="section">{row.text}</span>{/if}
      </div>
    {:else if row.kind === "note"}
      <div class="note">{row.text}</div>
    {:else}
      {@const split = parts(row)}
      <div class="line {row.kind}">
        <span class="num">{row.old ?? ""}</span><span class="num">{row.new ?? ""}</span><span class="marker">{row.kind === "add" ? "+" : row.kind === "remove" ? "−" : ""}</span><span class="code">{#if split}{split[0]}<mark>{split[1]}</mark>{split[2]}{:else}{row.text || " "}{/if}</span>
      </div>
    {/if}
  {/each}
</div>

<style>
  .udiff { --num: calc(var(--digits) * 7px + 14px); --marker: 16px; font-family: var(--mono); font-size: 11.5px; line-height: 1.5; padding-bottom: 8px; user-select: text; }
  .line { display: grid; grid-template-columns: var(--num) var(--num) var(--marker) 1fr; align-items: start; }
  .num { color: var(--text3); font-size: 10.5px; text-align: right; padding-right: 7px; background: color-mix(in srgb, var(--smoke) 50%, transparent); user-select: none; }
  .marker { text-align: center; font-weight: 600; user-select: none; }
  .code { white-space: pre-wrap; word-break: break-word; padding-right: 28px; color: #d9d7e0; }
  .context .code { opacity: 0.82; }
  .add { background: color-mix(in srgb, var(--mint) 8%, transparent); }
  .add .num { background: color-mix(in srgb, var(--mint) 16%, transparent); }
  .add .marker { color: var(--mint); }
  .add mark { background: color-mix(in srgb, var(--mint) 32%, transparent); color: inherit; border-radius: 2px; }
  .remove { background: color-mix(in srgb, var(--coral) 8%, transparent); }
  .remove .num { background: color-mix(in srgb, var(--coral) 16%, transparent); }
  .remove .marker { color: var(--coral); }
  .remove mark { background: color-mix(in srgb, var(--coral) 32%, transparent); color: inherit; border-radius: 2px; }
  .hunk { display: flex; align-items: center; gap: 8px; margin-top: 6px; padding: 5px 0; font-size: 10.5px; color: #8ab4f8; background: rgba(138, 180, 248, 0.07); border-top: 1px solid var(--line2); border-bottom: 1px solid var(--line2); }
  .gutter2 { width: calc(var(--num) * 2); text-align: center; flex: none; opacity: 0.8; }
  .hlabel { padding-left: var(--marker); flex: none; }
  .section { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .file { padding: 8px 12px; font-weight: 600; background: var(--graphite); border-bottom: 1px solid var(--line2); margin-top: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .file.first { margin-top: 0; }
  .note { padding: 3px 0 3px calc(var(--num) * 2 + var(--marker)); font-size: 10.5px; font-style: italic; color: var(--text3); }
</style>
