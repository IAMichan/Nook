<script lang="ts">
  // A mark per question of yours on the conversation's leading edge (`TranscriptPromptRail`): a click jumps to it, the
  // mark under the pointer grows as icons in a dock do (its neighbours a little), and its tooltip is what you asked.
  // It stays in sight while the margin beside the column is as wide as the rail; with less room it shows while the
  // pointer is on the edge. The newest marks that fit are drawn, 8 px apart, closer (4 px at least) when there are many.
  import { tip } from "./ui/tip";

  export type PromptMark = { id: string; text: string };
  let { marks, room, column, onselect }: { marks: PromptMark[]; room: number; column: number; onselect: (id: string) => void } = $props();

  const WIDTH = 20, PITCH = 8, MIN_PITCH = 4;
  let height = $state(0);
  let el = $state<HTMLDivElement | null>(null);
  $effect(() => {
    if (!el) return;
    let frame = 0;
    const observer = new ResizeObserver(() => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => (height = el?.clientHeight ?? 0));
    });
    observer.observe(el);
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  });
  let hovered = $state<string | null>(null);
  let onRail = $state(false);

  const layout = $derived.by(() => {
    if (!marks.length || height <= 0) return { pitch: PITCH, fit: 0 };
    const step = Math.min(PITCH, Math.max(MIN_PITCH, height / marks.length));
    return { pitch: step, fit: Math.max(1, Math.min(marks.length, Math.floor(height / step))) };
  });
  const shown = $derived(marks.slice(marks.length - layout.fit));
  const lit = $derived(hovered ? shown.findIndex((m) => m.id === hovered) : -1);
  /** `railAlwaysShown`: the margin beside the centered column holds the rail. */
  const inSight = $derived(onRail || room === 0 || (room - Math.min(room, column)) / 2 >= WIDTH);

  function size(distance: number | null): { w: number; h: number } {
    if (distance === 0) return { w: 14, h: 3 };
    if (distance === 1) return { w: 11, h: 2 };
    return { w: 8, h: 1.5 };
  }
  const prompt = (text: string) => (text.length > 600 ? text.slice(0, 599) + "…" : text.trim());
</script>

<div class="rail" class:shown={inSight} bind:this={el} role="navigation"
  onmouseenter={() => (onRail = true)} onmouseleave={() => { onRail = false; hovered = null; }}>
  <div class="marks">
    {#each shown as mark, i (mark.id)}
      {@const s = size(lit < 0 ? null : Math.abs(lit - i))}
      <button type="button" class="mark" style:height="{layout.pitch}px" use:tip={prompt(mark.text)} aria-label={prompt(mark.text)}
        onmouseenter={() => (hovered = mark.id)} onclick={() => onselect(mark.id)}>
        <span class="bar" class:lit={lit === i} style:width="{s.w}px" style:height="{Math.min(s.h, Math.max(1, layout.pitch - 2))}px"></span>
      </button>
    {/each}
  </div>
</div>

<style>
  .rail { position: absolute; left: var(--space-24); top: var(--space-8); bottom: var(--space-8); width: 20px; display: flex; align-items: center; opacity: 0; transition: opacity var(--motion-hover); z-index: 2; }
  .rail.shown { opacity: 1; }
  .marks { display: flex; flex-direction: column; width: 100%; }
  .mark { all: unset; cursor: pointer; width: 20px; display: flex; align-items: center; padding-left: var(--space-4); box-sizing: border-box; }
  .bar { display: block; border-radius: 999px; background: var(--text3); transition: width var(--motion-hover), height var(--motion-hover), background var(--motion-hover); }
  .bar.lit { background: var(--paper); }
  .mark:focus-visible .bar { background: var(--paper); }
  @media (prefers-reduced-motion: reduce) { .bar, .rail { transition: none; } }
</style>
