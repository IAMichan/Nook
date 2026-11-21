<script lang="ts">
  // How far your own message got (`MessageTicksMark`): a clock, one grey tick, two grey, two blue, or failed. After a
  // bubble's time and in front of a chat's newest message in the list, for every chat app.
  import type { WhatsAppReceipt } from "../../lib/connectors";
  import { ticks } from "../../lib/whatsapp";
  import Ico from "../../components/ui/Ico.svelte";

  let { receipt, size = 12, detail = null, onclick }: {
    receipt: WhatsAppReceipt | null | undefined;
    size?: number;
    detail?: string | null;
    onclick?: (e: MouseEvent) => void;
  } = $props();
  const mark = $derived(ticks(receipt));
  const tip = $derived(detail || mark?.title || "");
  const icon = $derived(receipt === "pending" ? "clock" : receipt === "failed" ? "circle-alert" : receipt === "sent" ? "check" : "check-check");
</script>

{#if mark}
  {#if onclick}
    <button type="button" class="ticks interactive {mark.tone}" title={tip} aria-label={tip} {onclick}><Ico name={icon} {size} stroke={receipt === "pending" ? 2 : 2.6} /></button>
  {:else}
    <span class="ticks {mark.tone}" title={tip} aria-label={tip}><Ico name={icon} {size} stroke={receipt === "pending" ? 2 : 2.6} /></span>
  {/if}
{/if}

<style>
  .ticks { display: inline-flex; align-items: center; flex: none; color: var(--chat-stamp); }
  .ticks.interactive { padding: 0; border: 0; background: none; cursor: pointer; }
  .ticks.interactive:hover:not(:disabled) { opacity: 0.82; background: none; border: 0; }
  .ticks.read { color: var(--blue); }
  .ticks.failed { color: var(--coral); }
</style>
