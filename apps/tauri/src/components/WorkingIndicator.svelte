<script lang="ts">
  // What Nook is doing right now, as an agent session shows it (the Mac's `TypingIndicator`): a pulsing dot, the current
  // step shimmering, and how long the answer has been going once it takes a moment.
  import { onDestroy } from "svelte";
  import { tr } from "../lib/i18n.svelte";
  import { elapsedLabel } from "../lib/working";

  let { status = "", since }: { status?: string; since?: string } = $props();
  const label = $derived(status || tr("Nook denkt na", "Nook is thinking"));
  const start = $derived(since ? Date.parse(since) : NaN);
  let now = $state(Date.now());
  const timer = setInterval(() => (now = Date.now()), 1000);
  onDestroy(() => clearInterval(timer));
  const elapsed = $derived(Number.isNaN(start) ? null : elapsedLabel((now - start) / 1000));
</script>

<div class="working" role="status" aria-label={label}>
  <span class="dot"></span>
  <span class="label">{label}</span>
  {#if elapsed}<span class="time">{elapsed}</span>{/if}
</div>

<style>
  .working { display: flex; gap: 8px; align-items: center; font-size: 12px; padding: 2px 0; min-width: 0; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--iris); flex: none; animation: pulse 1.4s ease-in-out infinite; }
  .label {
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0;
    color: var(--text2);
    background: linear-gradient(90deg, var(--text3) 0%, var(--paper) 50%, var(--text3) 100%) 0 0 / 200% 100%;
    -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
    animation: shimmer 2.2s linear infinite;
  }
  .time { color: var(--text3); font-variant-numeric: tabular-nums; flex: none; }
  @keyframes pulse { 0%, 100% { opacity: 0.45; transform: scale(0.85); } 50% { opacity: 1; transform: scale(1); } }
  @keyframes shimmer { from { background-position: 200% 0; } to { background-position: 0 0; } }
  @media (prefers-reduced-motion: reduce) {
    .dot, .label { animation: none; }
    .label { -webkit-text-fill-color: currentColor; background: none; }
  }
</style>
