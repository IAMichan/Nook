<script lang="ts">
  // Een stipje en de staat in woorden, overal dezelfde woorden.
  import { healthLabel, type Health } from "../../lib/connectors";

  let { health, text }: { health: Health; text?: string } = $props();
</script>

<span class="pill {health}">
  {#if health === "busy"}<span class="spin"></span>{:else}<span class="dot"></span>{/if}
  {text ?? healthLabel[health]}
</span>

<style>
  .pill { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; font-weight: 600; padding: 2px 9px; border-radius: 999px; background: var(--smoke); color: var(--text2); white-space: nowrap; }
  .dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
  .working { color: var(--mint); background: color-mix(in srgb, var(--mint) 14%, transparent); }
  .needsYou { color: var(--amber); background: color-mix(in srgb, var(--amber) 14%, transparent); }
  .broken { color: var(--coral); background: color-mix(in srgb, var(--coral) 14%, transparent); }
  .busy { color: var(--paper); }
  .spin { width: 8px; height: 8px; border-radius: 50%; border: 1.5px solid currentColor; border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
