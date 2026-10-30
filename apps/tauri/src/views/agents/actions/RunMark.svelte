<script lang="ts">
  // The outcome mark of a run or a job, the same marks a pull request's checks use (`CheckLog`): a tick, a cross, a
  // spinning ring while it runs, an amber dot while it waits, a dash when skipped, and a struck circle when cancelled.
  import type { RunOutcome } from "../../../lib/actions";

  let { outcome, running = false }: { outcome: RunOutcome; running?: boolean } = $props();
</script>

<span class="mark">
  {#if outcome === "passing"}<span class="good">✓</span>
  {:else if outcome === "failing"}<span class="bad">✕</span>
  {:else if outcome === "pending" && running}<span class="spin"></span>
  {:else if outcome === "pending"}<span class="dot waiting"></span>
  {:else if outcome === "cancelled"}<span class="faint">⊘</span>
  {:else}<span class="faint">–</span>{/if}
</span>

<style>
  .mark { width: 16px; display: grid; place-items: center; flex: none; }
  .spin { width: 10px; height: 10px; border-radius: 50%; border: 1.5px dashed var(--paper); animation: spin 1.6s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .good { color: var(--mint); }
  .bad { color: var(--coral); }
</style>
