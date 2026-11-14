<script lang="ts">
  // How far your message got (`MessageTicksMark`): a clock, one check, two checks, two blue checks, or a failure.
  import Ico from "./Ico.svelte";
  let { ticks, read = "var(--blue)", quiet = "var(--chat-stamp)" }: { ticks?: string; read?: string; quiet?: string } = $props();
</script>

{#if ticks === "pending"}<span class="t" style:color={quiet}><Ico name="clock" size={11} stroke={2.2} /></span>
{:else if ticks === "sent"}<span class="t" style:color={quiet}><Ico name="check" size={11} stroke={3} /></span>
{:else if ticks === "delivered" || ticks === "read"}<span class="t two" style:color={ticks === "read" ? read : quiet}><Ico name="check" size={11} stroke={3} /><Ico name="check" size={11} stroke={3} /></span>
{:else if ticks === "failed"}<span class="t" style:color="var(--coral)"><Ico name="circle-alert" size={12} stroke={2.4} /></span>{/if}

<style>
  .t { display: inline-flex; flex: none; position: relative; top: 1px; }
  .two :global(svg + svg) { margin-left: -6px; }
</style>
