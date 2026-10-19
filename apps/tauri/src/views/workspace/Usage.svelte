<script lang="ts">
  // Gebruik per agent en account: de 5-uurs- en weeklimiet, en tokens vandaag en deze week.
  import { agentNames, formatTokens, planLabel, total, type AgentKind } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";

  $effect(() => {
    agents.loadHistory();
  });

  const rows = $derived(
    Object.entries(agents.history?.usage ?? {}).map(([id, u]) => {
      const kind = (id.split("-")[0] as AgentKind) ?? "claude";
      return { id, name: agentNames[kind] ?? id, account: agents.history?.accounts[id], usage: u };
    }),
  );
</script>

<h3>Gebruik</h3>
<div class="group">
  {#each rows as r (r.id)}
    <div class="row">
      <div>
        <div>{r.name}{#if r.account} · <span class="muted">{r.account.name}</span>{/if}</div>
        <div class="faint small">
          vandaag {formatTokens(total(r.usage.today))} tokens · deze week {formatTokens(total(r.usage.week))} · {r.usage.sessionsWeek} sessies
        </div>
      </div>
      <div class="faint small">
        {#if r.id.startsWith("claude")}
          {planLabel(agents.overview?.profilePlanUsage[r.id] ?? (r.id === "claude" ? agents.overview?.planUsage : null)) || "limieten niet beschikbaar"}
        {:else}
          limieten niet beschikbaar
        {/if}
      </div>
    </div>
  {:else}
    <p class="faint note">Nog geen gebruik gevonden.</p>
  {/each}
</div>

<style>
  .small { font-size: 12px; }
</style>
