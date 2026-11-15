<script lang="ts">
  // One file's patch as the iPhone shows it: the new-side number, the line in the color of what happened to it, sideways
  // scrolling, and lines to pick (a tap, another for a range, a third starts over) for a comment.
  import { newNumbers } from "../../../lib/patch";
  import { tr } from "../../../lib/i18n.svelte";
  import { haptic } from "../../../lib/haptics";
  import Ico from "./Ico.svelte";
  let { patch, pickable = true, oncomment }: { patch: string; pickable?: boolean; oncomment?: (from: number, to: number, lines: string[]) => void } = $props();
  const lines = $derived(patch.replace(/\n$/, "").split("\n"));
  const numbers = $derived(newNumbers(lines));
  let first = $state<number | null>(null);
  let last = $state<number | null>(null);
  const lo = $derived(first === null ? -1 : Math.min(first, last ?? first));
  const hi = $derived(first === null ? -1 : Math.max(first, last ?? first));
  function pick(i: number) {
    if (!pickable || !oncomment || lines[i].startsWith("@@")) return;
    haptic();
    if (first === null || last !== null) { first = i; last = null; }
    else if (i === first) first = null;
    else last = i;
  }
  const tint = (l: string) => (l.startsWith("@@") ? "var(--blue)" : l.startsWith("+") ? "var(--mint)" : l.startsWith("-") ? "var(--coral)" : "var(--text-strong)");
</script>

<div class="patch">
  <div class="scroll">
    {#each lines as line, i (i)}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="line" class:picked={i >= lo && i <= hi} style:background={i >= lo && i <= hi ? "rgba(244,243,247,.16)" : `color-mix(in srgb, ${tint(line)} 7%, transparent)`} onclick={() => pick(i)}>
        <span class="num">{numbers[i] ?? ""}</span><span class="code" style:color={tint(line)}>{line || " "}</span>
      </div>
    {/each}
  </div>
  {#if first !== null && oncomment}
    <div class="pickbar">
      <span>{hi - lo + 1 === 1 ? tr("1 regel", "1 line") : tr("{n} regels", "{n} lines", { n: hi - lo + 1 })}</span>
      <button class="ghost" onclick={() => { first = null; last = null; }}>{tr("Wis", "Clear")}</button>
      <button class="primary" onclick={() => { oncomment?.(lo, hi, lines); first = null; last = null; }}><Ico name="message-square-text" size={14} />{tr("Commentaar", "Comment")}</button>
    </div>
  {/if}
</div>

<style>
  .patch { background: var(--well); }
  .scroll { overflow-x: auto; padding: 6px 0; }
  .line { display: flex; min-width: max-content; font: var(--pt-code); font-size: 13px; line-height: 1.55; }
  .num { width: 34px; flex: none; text-align: right; padding-right: 8px; color: var(--text3); user-select: none; }
  .code { white-space: pre; padding-right: 12px; }
  .pickbar { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-top: 0.5px solid var(--hairline); font: var(--pt-label); color: var(--text2); }
  .pickbar span { flex: 1; }
  .ghost { height: 32px; padding: 0 10px; color: var(--text2) !important; font: var(--pt-label) !important; }
  .primary { height: 32px; padding: 0 12px; border-radius: 999px; background: var(--iris) !important; color: var(--on-iris) !important; font: 600 13px var(--font) !important; display: inline-flex; align-items: center; gap: 6px; }
</style>
