<script lang="ts">
  // The message an answer goes to (`ChatQuote`): a bar in the writer's color (mint for yours, blue for theirs), who
  // wrote it and the start of its text, on a faint fill. At the top of a bubble that answers one, and above the field
  // while you write an answer.
  import type { Snippet } from "svelte";
  let { sender, text, mine, trailing }: { sender: string; text: string; mine: boolean; trailing?: Snippet } = $props();
</script>

<div class="quote" class:mine>
  <span class="words">
    {#if sender}<span class="sender">{sender}</span>{/if}
    <span class="text">{text}</span>
  </span>
  {#if trailing}{@render trailing()}{/if}
</div>

<style>
  .quote { position: relative; display: flex; align-items: center; gap: var(--space-8); padding: var(--space-4) var(--space-8) var(--space-4) var(--space-12); border-radius: var(--radius-chip); background: color-mix(in srgb, var(--paper) 5%, transparent); min-width: 0; }
  .quote::before { content: ""; position: absolute; left: var(--space-4); top: var(--space-4); bottom: var(--space-4); width: 3px; border-radius: 999px; background: var(--blue); }
  .quote.mine::before { background: var(--mint); }
  .words { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .sender { font: var(--text-label); color: var(--blue); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .mine .sender { color: var(--mint); }
  .text { font: var(--text-detail); color: var(--text2); overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow-wrap: anywhere; }
</style>
