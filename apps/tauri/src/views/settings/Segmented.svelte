<script lang="ts" module>
  export interface SegmentedOption<T extends string = string> { value: T; label: string }
</script>

<script lang="ts" generics="T extends string">
  // A choice of two to four on a Settings row, drawn as the Mac's segmented picker: the options side by side in one
  // capsule, the chosen one raised. ← and → move the choice, as in any radio group.
  let { options, value, label, onchange }: { options: SegmentedOption<T>[]; value: T; label: string; onchange: (value: T) => void } = $props();

  function keys(e: KeyboardEvent) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    const i = options.findIndex((o) => o.value === value);
    const next = options[(i + (e.key === "ArrowRight" ? 1 : options.length - 1)) % options.length];
    onchange(next.value);
    (e.currentTarget as HTMLElement).querySelector<HTMLElement>(`[data-value="${next.value}"]`)?.focus();
  }
</script>

<div class="segmented" role="radiogroup" tabindex="-1" aria-label={label} onkeydown={keys}>
  {#each options as option (option.value)}
    <button type="button" role="radio" data-value={option.value} class:on={option.value === value} aria-checked={option.value === value}
      tabindex={option.value === value ? 0 : -1} onclick={() => option.value !== value && onchange(option.value)}>{option.label}</button>
  {/each}
</div>

<style>
  /* The Mac's segmented picker at the large control size of a Settings row: one capsule 28 px high, every segment the
     same width, the text in body type, the chosen one raised. */
  .segmented { display: inline-grid; grid-auto-flow: column; grid-auto-columns: 1fr; flex: none; gap: var(--space-2); padding: var(--space-2); border-radius: var(--radius-pill); background: var(--settings-fill); }
  button { border: none; background: none; color: var(--text-strong); height: 24px; padding: 0 var(--space-12); border-radius: var(--radius-pill); font: var(--text-body); line-height: 24px; white-space: nowrap; }
  button:hover:not(:disabled) { background: none; color: var(--paper); }
  button.on, button.on:hover:not(:disabled) { background: var(--settings-fill-on); color: var(--paper); }
</style>
