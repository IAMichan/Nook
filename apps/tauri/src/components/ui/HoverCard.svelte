<script lang="ts">
  // A detail card on hover (`HoverCard`): it opens after a short rest and stays while the pointer is on the view or on
  // the card, and a moment after, so what it holds can be clicked. A `HoverCardButton`-style line inside closes it by
  // calling `close`.
  import type { Snippet } from "svelte";
  let { children, card, edge = "bottom" }: { children: Snippet; card: Snippet<[() => void]>; edge?: "top" | "bottom" } = $props();
  let open = $state(false);
  let openTimer: ReturnType<typeof setTimeout> | undefined;
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  const enter = () => {
    clearTimeout(closeTimer);
    if (!open) openTimer = setTimeout(() => (open = true), 300);
  };
  const leave = () => {
    clearTimeout(openTimer);
    closeTimer = setTimeout(() => (open = false), 250);
  };
  const close = () => {
    clearTimeout(openTimer);
    clearTimeout(closeTimer);
    open = false;
  };
  $effect(() => () => { clearTimeout(openTimer); clearTimeout(closeTimer); });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<span class="host" onpointerenter={enter} onpointerleave={leave} onfocusin={enter} onfocusout={leave}>
  {@render children()}
  {#if open}
    <div class="card {edge}" role="tooltip">{@render card(close)}</div>
  {/if}
</span>

<style>
  .host { position: relative; display: inline-flex; }
  .card { position: absolute; left: 0; z-index: 60; min-width: 220px; max-width: 340px; padding: var(--space-8); background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); animation: fade 120ms ease-out; }
  .card.bottom { top: calc(100% + 4px); }
  .card.top { bottom: calc(100% + 4px); }
  @keyframes fade { from { opacity: 0; } }
</style>
