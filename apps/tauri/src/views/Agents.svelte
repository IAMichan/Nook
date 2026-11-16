<script lang="ts">
  // Agents: sessies van Claude Code, Codex en de andere coding-agents, in de balk (compact) en in het hoofdvenster.
  import { nook } from "../lib/state.svelte";
  import AgentsTab from "./agents/AgentsTab.svelte";
  import { tr } from "../lib/i18n.svelte";

  let { compact = false }: { compact?: boolean } = $props();
  const local = $derived(nook.info?.capabilities.localAgents ?? false);
</script>

{#if !nook.info}
  <div class="empty"><p class="faint">{tr("Laden…", "Loading…")}</p></div>
{:else if !local}
  <div class="empty">
    <p>{tr("Agents draaien op je computer, niet op je telefoon.", "Agents run on your computer, not on your phone.")}</p>
    <p class="faint">
      {tr("Claude Code, Codex en de andere coding-agents werken in een terminal op je Windows- of Linux-computer (of je Mac). Open Nook daar om ze te volgen, goed te keuren en nieuwe sessies te starten; op de telefoon zie je ze via de companion zodra die gekoppeld is.", "Claude Code, Codex and the other coding agents work in a terminal on your Windows or Linux computer (or your Mac). Open Nook there to follow them, approve them and start new sessions; on your phone you see them through the companion once it is paired.")}
    </p>
  </div>
{:else}
  <AgentsTab {compact} />
{/if}

<style>
  .empty { padding: 24px; text-align: center; max-width: 520px; margin: 0 auto; }
</style>
