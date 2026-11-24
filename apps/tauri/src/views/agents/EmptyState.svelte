<script lang="ts">
  // A calm, centered invitation where a list or page has nothing yet (the Mac's `WSEmptyState`): a light symbol, a title,
  // a line of explanation and at most one primary button.
  import type { Snippet } from "svelte";
  import Ico from "../../components/ui/Ico.svelte";

  let { symbol, title, message, action, children }: {
    symbol: string;
    title: string;
    message?: string;
    action?: { title: string; run: () => void };
    children?: Snippet;
  } = $props();
</script>

<div class="empty-state">
  <span class="symbol"><Ico name={symbol} size={30} stroke={1.5} /></span>
  <p class="title">{title}</p>
  {#if message}<p class="message">{message}</p>{/if}
  {#if action}<button class="primary go" onclick={action.run}>{action.title}</button>{/if}
  {@render children?.()}
</div>

<style>
  .empty-state { display: flex; flex-direction: column; align-items: center; gap: 10px; margin: auto; padding: var(--space-24); text-align: center; }
  .symbol { display: inline-flex; color: var(--text3); }
  .title { margin: 0; font: var(--text-title); color: var(--paper); }
  .message { margin: 0; max-width: 380px; font: var(--text-body); color: var(--text2); }
  /* `NookPrimaryButton`: 14 pt semibold on the accent, 38 pt tall. */
  .go { height: 38px; margin-top: var(--space-4); padding: 0 var(--space-16); border-radius: var(--radius-control); font: var(--text-body); font-weight: 600; }
</style>
