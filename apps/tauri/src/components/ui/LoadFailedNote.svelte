<script lang="ts">
  // A part that could not load inside a view that did (`LoadFailedNote`): the reason in soft coral, a retry, and an
  // optional extra button ("Open in Mail").
  import { tr } from "../../lib/i18n.svelte";
  let { reason, onretry, retryTitle, extra }: {
    reason: string; onretry?: () => void; retryTitle?: string; extra?: { title: string; onclick: () => void };
  } = $props();
</script>

<div class="failed" role="alert">
  <span class="reason">{reason}</span>
  {#if onretry}<button class="ghost" onclick={onretry}>{retryTitle ?? tr("Probeer opnieuw", "Try again")}</button>{/if}
  {#if extra}<button class="ghost" onclick={extra.onclick}>{extra.title}</button>{/if}
</div>

<style>
  .failed { display: flex; align-items: center; flex-wrap: wrap; gap: var(--space-8); padding: var(--space-6) 0; }
  .reason { font: var(--text-detail); color: var(--coral-soft); min-width: 0; }
  button { padding: var(--space-2) var(--space-8); font: var(--text-control); }
</style>
