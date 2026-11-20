<script lang="ts">
  // Settings › Coding agents › Usage & costs (`usageSection` on the Mac): the weekly recap and whether costs show, then
  // the subscriptions' limits, then the tokens and costs of the sessions Nook started.
  import { tr } from "../../lib/i18n.svelte";
  import { services, type RecapView } from "../../lib/services";
  import { workspaceApi, type RunProvider, type UsageRange } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Usage from "../workspace/Usage.svelte";
  import UsagePage from "../workspace/UsagePage.svelte";

  $effect(() => {
    workspace.start();
  });

  // The period and agent of the sessions' figures, as rows of the card (the Mac's Period and Agent pickers).
  let range = $state<UsageRange>((localStorage.getItem("ws.usage.range") as UsageRange) || "week");
  let provider = $state<RunProvider | "">("");

  // The recap opens under its row, as the Mac's View shows the week's sheet.
  let recap = $state<RecapView | null>(null);
  let recapOpen = $state(false);
  async function toggleRecap() {
    recapOpen = !recapOpen;
    if (recapOpen && !recap) recap = await services.recap().catch(() => null);
  }

  async function setShowCost(on: boolean) {
    const current = workspace.settings;
    if (current) await workspaceApi.saveSettings({ ...$state.snapshot(current), showCost: on }).catch(() => {});
  }
</script>

<div class="group">
  <div class="row">
    <span>{tr("Weekoverzicht", "Weekly recap")}<br /><small>{tr("Wat al je agents deze week voor je deden: tijd, sessies, regels code en wie het meest werkte.", "What all your agents did for you this week: time, sessions, lines of code and who worked the most.")}</small></span>
    <button class="capsule" onclick={toggleRecap}>{tr("Bekijk", "View")}</button>
  </div>
  {#if recapOpen && recap}
    <p class="note">{recap.label} · {recap.duration}{#if recap.busiest} · {recap.busiest}{/if}</p>
  {/if}
  <label class="row">
    <span>{tr("Kosten tonen die agents zelf melden", "Show costs reported by agents")}</span>
    <input type="checkbox" role="switch" checked={workspace.settings?.showCost ?? true} onchange={(e) => setShowCost(e.currentTarget.checked)} />
  </label>
</div>

<h3>{tr("Abonnementen", "Subscriptions")}</h3>
<p class="section-info">{tr("Dit is je hele account, niet alleen de werkruimte. Claude meldt het via de statusregel (koppelen in Instellingen › Agents); Codex alleen voor het eerste account. Meldt een agent niets, dan toont Nook niets.", "This is your whole account, not just the workspace. Claude reports it via the status line (connect it in Settings › Agents); Codex only for the first account. If an agent reports nothing, Nook shows nothing.")}</p>
<Usage heading={false} />

<h3>{tr("Sessies gestart in Nook", "Sessions started in Nook")}</h3>
<p class="section-info">{tr("Alleen sessies die Nook in de werkruimte startte. Sessies in je eigen terminal zie je in de Agents-tab.", "Only sessions Nook started in the workspace. Sessions in your own terminal are in the Agents tab.")}</p>
<div class="group sessions">
  <label class="row">
    <span>{tr("Periode", "Period")}</span>
    <select bind:value={range}>
      <option value="today">{tr("Vandaag", "Today")}</option>
      <option value="week">{tr("7 dagen", "7 days")}</option>
      <option value="month">{tr("30 dagen", "30 days")}</option>
      <option value="all">{tr("Alles", "All")}</option>
    </select>
  </label>
  <label class="row">
    <span>{tr("Agent", "Agent")}</span>
    <select bind:value={provider}>
      <option value="">{tr("Alle agents", "All agents")}</option>
      {#each workspace.providers.filter((p) => p.supported) as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}
    </select>
  </label>
  <div class="report"><UsagePage part="cost" controls={false} bind:range bind:provider /></div>
</div>

<style>
  small { font: var(--text-detail); line-height: 1.3; display: inline-block; }
  .report { padding: var(--space-12) 0; }
</style>
