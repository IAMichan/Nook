<script lang="ts">
  // Gebruik per agent en account: de 5-uurs- en weeklimiet, en tokens vandaag en deze week.
  import { agentNames, formatTokens, planLabel, total, type AgentKind } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";

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

<h3>{tr("Gebruik", "Usage")}</h3>
<div class="group">
  {#each rows as r (r.id)}
    <div class="row">
      <div>
        <div>{r.name}{#if r.account} · <span class="muted">{r.account.name}</span>{/if}</div>
        <div class="faint small">
          {tr("vandaag {today} tokens · deze week {week} · {n} sessies", "today {today} tokens · this week {week} · {n} sessions", { today: formatTokens(total(r.usage.today)), week: formatTokens(total(r.usage.week)), n: r.usage.sessionsWeek })}
        </div>
      </div>
      <div class="faint small">
        {#if r.id.startsWith("claude")}
          {planLabel(agents.overview?.profilePlanUsage[r.id] ?? (r.id === "claude" ? agents.overview?.planUsage : null)) || tr("limieten niet beschikbaar", "limits not available")}
        {:else}
          {tr("limieten niet beschikbaar", "limits not available")}
        {/if}
      </div>
    </div>
  {:else}
    <p class="faint note">{tr("Nog geen gebruik gevonden.", "No usage found yet.")}</p>
  {/each}
</div>

<style>
  .small { font-size: 12px; }
</style>
