<script lang="ts">
  // A session's state as a mark and a word in its color (`StatusBadgeLabel`), short in a row's corner.
  import { attentionTint, attentionWord, shortAttentionWord } from "../../lib/companion";
  import Ico from "./Ico.svelte";
  import PulseDot from "./PulseDot.svelte";
  let { attention, short = true }: { attention: string; short?: boolean } = $props();
  const marks: Record<string, string> = { approval: "shield-half", input: "message-circle-question", failed: "triangle-alert", limited: "hourglass", ready: "circle-check", finished: "circle-check", idle: "moon" };
  const filled = $derived(attention === "approval" || attention === "input" || attention === "ready" || attention === "failed");
</script>

<span class="pill" style:color={attentionTint(attention)}>
  <span class="markbox">
    {#if attention === "working"}<PulseDot size={6} />{:else}<Ico name={marks[attention] ?? "moon"} size={11} stroke={filled ? 2.4 : 2.2} />{/if}
  </span>
  <span>{short ? shortAttentionWord(attention) : attentionWord(attention)}</span>
</span>

<style>
  .pill { display: inline-flex; align-items: center; gap: 4px; min-height: 18px; padding: 0 4px; font: var(--pt-label, var(--text-label)); white-space: nowrap; flex: none; }
  .markbox { width: 12px; height: 12px; display: inline-flex; align-items: center; justify-content: center; }
</style>
