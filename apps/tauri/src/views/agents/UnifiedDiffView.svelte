<script lang="ts">
  // A unified diff as a code review shows it (DiffText on the Mac): line numbers of the old and new file in a gutter,
  // hunks as separators with their section name, added and removed lines tinted, and the changed words of an edited
  // line highlighted. Long lines wrap instead of scrolling sideways, which suits the side panel.
  //
  // With `onhunk` a hunk's header offers Stage and Discard (`HunkPatch`); with `oncomment` each line takes a comment for
  // the agent (`ReviewComments`), written in a field under the line.
  import { diffRows, hunkLabel, type DiffRow } from "../../lib/workspace/unifiedDiff";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  let {
    diff,
    onhunk,
    oncomment,
    comments = [],
  }: {
    diff: string;
    /** Stage or discard the hunk with this number, counted from the first. */
    onhunk?: (index: number, action: "stage" | "discard") => void;
    oncomment?: (row: DiffRow, text: string) => void;
    /** Comments already made, shown under their line: the line's raw text and new line number. */
    comments?: { code: string; line: number | null; text: string }[];
  } = $props();
  const rows = $derived(diffRows(diff));
  // Width of one line-number column, from the largest number in the diff.
  const digits = $derived(Math.max(2, String(rows.reduce((m, r) => Math.max(m, r.old ?? 0, r.new ?? 0), 0)).length));

  /// The number of each hunk header, by its row.
  const hunkNumbers = $derived.by(() => {
    const out = new Map<number, number>();
    rows.forEach((r, i) => { if (r.kind === "hunk") out.set(i, out.size); });
    return out;
  });

  let writing = $state<number | null>(null);
  let note = $state("");
  function save(row: DiffRow) {
    if (note.trim()) oncomment?.(row, note.trim());
    note = "";
    writing = null;
  }
  const commentsFor = (row: DiffRow) => comments.filter((c) => c.code === row.raw && c.line === (row.kind === "remove" ? null : row.new));

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
        {#if onhunk}
          <span class="hunk-actions">
            <button class="hb" title={tr("Dit blok stagen", "Stage this hunk")} aria-label={tr("Dit blok stagen", "Stage this hunk")} onclick={() => onhunk(hunkNumbers.get(i) ?? 0, "stage")}><Ico name="check" size={12} stroke={2.4} /></button>
            <button class="hb" title={tr("Dit blok weggooien", "Discard this hunk")} aria-label={tr("Dit blok weggooien", "Discard this hunk")} onclick={() => onhunk(hunkNumbers.get(i) ?? 0, "discard")}><Ico name="x" size={12} stroke={2.4} /></button>
          </span>
        {/if}
      </div>
    {:else if row.kind === "note"}
      <div class="note">{row.text}</div>
    {:else}
      {@const split = parts(row)}
      <div class="line {row.kind}" class:commentable={!!oncomment}>
        <span class="num">{row.old ?? ""}</span><span class="num">{row.new ?? ""}</span><span class="marker">{#if oncomment}<button class="add-comment" title={tr("Opmerking bij deze regel", "Comment on this line")} aria-label={tr("Opmerking bij deze regel", "Comment on this line")} onclick={() => { writing = i; note = ""; }}><Ico name="plus" size={10} stroke={2.6} /></button>{/if}<span class="sign">{row.kind === "add" ? "+" : row.kind === "remove" ? "−" : ""}</span></span><span class="code">{#if split}{split[0]}<mark>{split[1]}</mark>{split[2]}{:else}{row.text || " "}{/if}</span>
      </div>
      {#each commentsFor(row) as c, ci (ci)}
        <div class="comment"><Ico name="message-square" size={12} /><span>{c.text}</span></div>
      {/each}
      {#if writing === i}
        <div class="comment-form">
          <!-- svelte-ignore a11y_autofocus -->
          <textarea bind:value={note} rows="2" autofocus placeholder={tr("Wat moet hier anders?", "What should change here?")}
            onkeydown={(e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); save(row); } if (e.key === "Escape") writing = null; }}></textarea>
          <div class="form-actions">
            <button class="ghost small" onclick={() => (writing = null)}>{tr("Annuleer", "Cancel")}</button>
            <button class="primary small" disabled={!note.trim()} onclick={() => save(row)}>{tr("Bewaar", "Save")}</button>
          </div>
        </div>
      {/if}
    {/if}
  {/each}
</div>

<style>
  .udiff { --num: calc(var(--digits) * 7px + 14px); --marker: 16px; font-family: var(--mono); font-size: 11.5px; line-height: 1.5; padding-bottom: 8px; user-select: text; }
  .line { display: grid; grid-template-columns: var(--num) var(--num) var(--marker) 1fr; align-items: start; }
  .num { color: var(--text3); font-size: 10.5px; text-align: right; padding-right: 7px; background: color-mix(in srgb, var(--smoke) 50%, transparent); user-select: none; }
  .marker { text-align: center; font-weight: 600; user-select: none; }
  .code { white-space: pre-wrap; word-break: break-word; padding-right: 28px; color: var(--text-strong); }
  .context .code { opacity: 0.82; }
  .add { background: color-mix(in srgb, var(--mint) 8%, transparent); }
  .add .num { background: color-mix(in srgb, var(--mint) 16%, transparent); }
  .add .marker { color: var(--mint); }
  .add mark { background: color-mix(in srgb, var(--mint) 32%, transparent); color: inherit; border-radius: 2px; }
  .remove { background: color-mix(in srgb, var(--coral) 8%, transparent); }
  .remove .num { background: color-mix(in srgb, var(--coral) 16%, transparent); }
  .remove .marker { color: var(--coral); }
  .remove mark { background: color-mix(in srgb, var(--coral) 32%, transparent); color: inherit; border-radius: 2px; }
  .hunk { display: flex; align-items: center; gap: 8px; margin-top: 6px; padding: 5px 0; font-size: 10.5px; color: var(--blue); background: rgba(138, 180, 248, 0.07); border-top: 1px solid var(--line2); border-bottom: 1px solid var(--line2); }
  .gutter2 { width: calc(var(--num) * 2); text-align: center; flex: none; opacity: 0.8; }
  .hlabel { padding-left: var(--marker); flex: none; }
  .section { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .file { padding: 8px 12px; font-weight: 600; background: var(--graphite); border-bottom: 1px solid var(--line2); margin-top: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .file.first { margin-top: 0; }
  .hunk-actions { margin-left: auto; display: inline-flex; gap: var(--space-2); padding-right: var(--space-8); }
  .hb { display: grid; place-items: center; width: 20px; height: 20px; margin: 0; padding: 0; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text2); }
  .hb:hover { background: var(--smoke); color: var(--paper); }
  .marker { position: relative; }
  .add-comment { position: absolute; inset: 0; display: none; place-items: center; margin: 0; padding: 0; border: 0; border-radius: var(--radius-chip); background: var(--blue); color: var(--canvas); }
  .commentable:hover .add-comment { display: grid; }
  .commentable:hover .sign { visibility: hidden; }
  .comment { display: flex; align-items: flex-start; gap: var(--space-6); margin: var(--space-2) var(--space-8) var(--space-4) calc(var(--num) * 2 + var(--marker)); padding: var(--space-6) var(--space-8); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--smoke); color: var(--paper); font-family: var(--font); white-space: pre-wrap; }
  .comment-form { display: flex; flex-direction: column; gap: var(--space-6); margin: var(--space-4) var(--space-8) var(--space-6) calc(var(--num) * 2 + var(--marker)); }
  .comment-form textarea { font: var(--text-body); resize: vertical; }
  .form-actions { display: flex; justify-content: flex-end; gap: var(--space-6); }
  .note { padding: 3px 0 3px calc(var(--num) * 2 + var(--marker)); font-size: 10.5px; font-style: italic; color: var(--text3); }
</style>
