<script lang="ts">
  // Agents: sessies van Claude Code, Codex en de andere coding-agents, in de balk (compact) en in het hoofdvenster.
  import { nook } from "../lib/state.svelte";
  import AgentsTab from "./agents/AgentsTab.svelte";

  let { compact = false }: { compact?: boolean } = $props();
  const local = $derived(nook.info?.capabilities.localAgents ?? false);
</script>

{#if !nook.info}
  <div class="empty"><p class="faint">Laden…</p></div>
{:else if !local}
  <div class="empty">
    <p>Agents draaien op je computer, niet op je telefoon.</p>
    <p class="faint">
      Claude Code, Codex en de andere coding-agents werken in een terminal op je Windows- of Linux-computer (of je Mac).
      Open Nook daar om ze te volgen, goed te keuren en nieuwe sessies te starten; op de telefoon zie je ze via de
      companion zodra die gekoppeld is.
    </p>
  </div>
{:else}
  <AgentsTab {compact} />
{/if}

<style>
  .empty { padding: 24px; text-align: center; max-width: 520px; margin: 0 auto; }
</style>
