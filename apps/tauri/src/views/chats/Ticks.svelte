<script lang="ts">
  // How far your own message got (`MessageTicksMark`): a clock, one grey tick, two grey, two blue, or failed. After a
  // bubble's time and in front of a chat's newest message in the list, for every chat app.
  import type { WhatsAppReceipt } from "../../lib/connectors";
  import { ticks } from "../../lib/whatsapp";
  import Ico from "../../components/ui/Ico.svelte";

  let { receipt, size = 12 }: { receipt: WhatsAppReceipt | null | undefined; size?: number } = $props();
  const mark = $derived(ticks(receipt));
  const icon = $derived(receipt === "pending" ? "clock" : receipt === "failed" ? "circle-alert" : receipt === "sent" ? "check" : "check-check");
</script>

{#if mark}<span class="ticks {mark.tone}" title={mark.title} aria-label={mark.title}><Ico name={icon} {size} stroke={receipt === "pending" ? 2 : 2.6} /></span>{/if}

<style>
  .ticks { display: inline-flex; flex: none; color: var(--chat-stamp); }
  .ticks.read { color: var(--blue); }
  .ticks.failed { color: var(--coral); }
</style>
