<script lang="ts">
  // Gebruik (`UsageView` op de Mac): de limieten van je accounts (5-uurs- en weeklimiet) en de tokens en kosten van
  // sessies in de werkruimte, per agent en model, zoals de agents ze zelf meldden. Wat niet gemeld is, blijft "niet
  // gemeld": Nook gokt nooit.
  import { formatTokens } from "../../lib/agents";
  import { workspaceApi, type RunProvider, type UsageRange, type UsageReport } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Usage from "./Usage.svelte";

  let range = $state<UsageRange>((localStorage.getItem("ws.usage.range") as UsageRange) || "week");
  let provider = $state<RunProvider | "">("");
  let report = $state<UsageReport | null>(null);
  let error = $state<string | null>(null);

  const showCost = $derived(workspace.settings?.showCost ?? true);

  $effect(() => {
    workspace.start();
    try {
      localStorage.setItem("ws.usage.range", range);
    } catch {
      // Geen opslag: de keuze geldt alleen nu.
    }
    void workspace.runs.length;
    workspaceApi
      .usage({ range, provider: provider || null, model: null, project: null })
      .then((r) => (report = r))
      .catch((e) => (error = String(e)));
  });

  const ranges: [UsageRange, string][] = [["today", "Vandaag"], ["week", "7 dagen"], ["month", "30 dagen"], ["all", "Alles"]];
  const name = (p: string) => workspace.provider(p)?.name ?? p;
  const cost = (v: number | null) => (v === null ? "niet gemeld" : `$${v.toFixed(2)}`);
  const days = $derived.by(() => {
    const map = new Map<string, number>();
    for (const d of report?.days ?? []) map.set(d.day, (map.get(d.day) ?? 0) + d.tokens);
    return [...map.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  });
  const maxDay = $derived(Math.max(1, ...days.map((d) => d[1])));
</script>

<div class="usage">
  <section>
    <Usage />
    <p class="faint small">
      Dit is je hele account, niet alleen de werkruimte. Claude meldt het via de statusregel (koppelen in Instellingen ›
      Agents); Codex alleen voor het eerste account. Meldt een agent niets, dan toont Nook "niet beschikbaar".
    </p>
  </section>

  <section>
    <div class="head">
      <div>
        <h3>Werkruimte</h3>
        <div class="faint small">Tokens en kosten van sessies in de werkruimte, zoals de agents ze zelf meldden.</div>
      </div>
      <span class="spacer"></span>
      <select bind:value={provider}>
        <option value="">Alle agents</option>
        {#each workspace.providers.filter((p) => p.supported) as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}
      </select>
      <div class="seg">
        {#each ranges as [r, label] (r)}<button class:on={range === r} onclick={() => (range = r)}>{label}</button>{/each}
      </div>
    </div>
    {#if error}<p class="err">{error}</p>{/if}
    {#if report}
      {#if !report.sessions}
        <p class="faint">Nog geen gebruik in deze periode.</p>
      {:else}
        <div class="cards">
          <div class="card"><span class="faint">Sessies</span><strong>{report.sessions}</strong><span class="faint small">{report.completed} klaar · {report.failed} mislukt · {report.running} bezig</span></div>
          <div class="card"><span class="faint">Input</span><strong>{formatTokens(report.inputTokens)}</strong><span class="faint small">{report.sessionsWithTokens} van {report.sessions} sessies met cijfers</span></div>
          <div class="card"><span class="faint">Output</span><strong>{formatTokens(report.outputTokens)}</strong></div>
          <div class="card"><span class="faint">Cache gelezen</span><strong>{formatTokens(report.cacheReadTokens)}</strong>{#if report.cacheWriteTokens}<span class="faint small">+{formatTokens(report.cacheWriteTokens)} geschreven</span>{/if}</div>
          <div class="card">
            <span class="faint">Kosten</span>
            {#if !showCost}<strong class="faint">verborgen</strong><span class="faint small">verborgen in instellingen</span>
            {:else if report.reportedCostUsd === null}<strong class="faint">—</strong><span class="faint small">geen agent meldde kosten</span>
            {:else}<strong>{cost(report.reportedCostUsd)}</strong><span class="faint small">gemeld door {report.sessionsWithCost} van {report.sessions} sessies</span>{/if}
          </div>
        </div>
        {#if report.running}<p class="faint small">Tokens van een lopende beurt komen binnen als de beurt klaar is.</p>{/if}
        {#if days.length}
          <h4>Tokens per dag</h4>
          <div class="chart">
            {#each days as [day, tokens] (day)}
              <div class="bar" title={`${day}: ${formatTokens(tokens)}`}><span style:height="{(tokens / maxDay) * 100}%"></span><em>{day.slice(5)}</em></div>
            {/each}
          </div>
        {/if}
        <h4>Per agent en model</h4>
        <div class="table">
          <div class="row header faint"><span>Agent · model</span><span>Sessies</span><span>Input</span><span>Output</span><span>Cache</span>{#if showCost}<span>Kosten</span>{/if}</div>
          {#each report.rows as r (r.provider + r.model)}
            <div class="row">
              <span>{name(r.provider)} · <span class="mono">{r.model}</span></span>
              <span>{r.sessions}{#if r.sessionsWithoutTokens} <span class="faint">({r.sessionsWithoutTokens} zonder cijfers)</span>{/if}</span>
              <span>{formatTokens(r.inputTokens)}</span>
              <span>{formatTokens(r.outputTokens)}</span>
              <span>{formatTokens(r.cacheReadTokens)}</span>
              {#if showCost}<span>{r.provider === "claude" || r.reportedCostUsd !== null ? cost(r.reportedCostUsd) : `${name(r.provider)} meldt geen kosten.`}</span>{/if}
            </div>
          {/each}
        </div>
        <p class="faint small">
          Claude Code: tokens en kosten komen uit zijn eigen eindmelding per beurt; de kosten rekent hij tegen API-prijzen
          uit (met een abonnement betaal je die niet per token). Codex meldt geen kosten en geen contextgrootte. Alleen
          sessies die Nook in de werkruimte startte.
        </p>
      {/if}
    {/if}
  </section>
</div>

<style>
  .usage { display: flex; flex-direction: column; gap: 18px; height: 100%; overflow-y: auto; }
  section { display: flex; flex-direction: column; gap: 8px; }
  h3 { margin: 0; font-size: 14px; }
  h4 { margin: 8px 0 0; font-size: 12px; color: var(--text2); }
  .head { display: flex; gap: 8px; align-items: center; }
  .spacer { flex: 1; }
  .seg { display: flex; gap: 2px; background: var(--graphite); border-radius: 9px; padding: 2px; }
  .seg button { background: none; border: none; font-size: 12px; padding: 3px 8px; border-radius: 7px; }
  .seg button.on { background: var(--smoke); }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 8px; }
  .card { display: flex; flex-direction: column; gap: 2px; padding: 10px; border-radius: 10px; background: var(--graphite); font-size: 12px; }
  .card strong { font-size: 17px; }
  .chart { display: flex; gap: 4px; align-items: flex-end; height: 90px; }
  .bar { flex: 0 1 48px; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; height: 100%; gap: 2px; }
  .bar span { width: 100%; background: var(--text2); border-radius: 3px 3px 0 0; min-height: 2px; }
  .bar em { font-size: 9.5px; color: var(--text3); font-style: normal; }
  .table { display: flex; flex-direction: column; gap: 2px; font-size: 12.5px; }
  .row { display: grid; grid-template-columns: 2.2fr 1fr 1fr 1fr 1fr 1.2fr; gap: 8px; padding: 6px 8px; border-radius: 8px; }
  .row.header { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .mono { font-family: var(--mono); font-size: 11.5px; }
  .small { font-size: 11.5px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
