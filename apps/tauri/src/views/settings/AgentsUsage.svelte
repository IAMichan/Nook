<script lang="ts">
  // Settings › Coding agents › Usage & costs (`usageSection` + `UsageView` on the Mac): weekly recap and cost toggle,
  // live subscription limit rows per account with even-pace ticks and reset credits (plus "All limits" opening the modal),
  // and tokens & costs of sessions started in Nook.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import {
    agentApi,
    agentEvents,
    agentNames,
    formatCompactDuration,
    formatUpcomingTime,
    usagePageUrl,
    type AccountLimits,
    type CliProxyHubSnapshot,
    type ResetOutcome,
  } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { services, type RecapView } from "../../lib/services";
  import { workspaceApi, type RunProvider, type UsageRange } from "../../lib/workspace/api";
  import {
    accountLimitsToPoolLimits,
    groupLimits,
    paceForLimit,
    timeElapsed,
    usageTone,
    usedOf,
    type AccountLimitInput,
    type LimitDisplay,
  } from "../../lib/workspace/limit-pool";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { tip } from "../../components/ui/tip";
  import UsageModal from "../agents/UsageModal.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import UsagePage from "../workspace/UsagePage.svelte";
  import CliProxyHubs from "./CliProxyHubs.svelte";
  import SettingsSection from "./SettingsSection.svelte";
  import TokenSettingsSection from "./TokenSettingsSection.svelte";

  // Period and agent of the sessions' figures, as rows of the card (the Mac's Period and Agent pickers).
  let range = $state<UsageRange>((localStorage.getItem("ws.usage.range") as UsageRange) || "week");
  let provider = $state<RunProvider | "">("");

  let recap = $state<RecapView | null>(null);
  let recapOpen = $state(false);
  let showLimitsModal = $state(false);
  let refreshing = $state(false);
  let now = $state(new Date());
  let accountLimits = $state<AccountLimits[]>([]);
  let cliproxyHubs = $state<CliProxyHubSnapshot[]>([]);
  let creditOutcomes = $state<Record<string, ResetOutcome | null>>({});
  let redeemingLocal = $state<Record<string, boolean>>({});

  async function loadCliProxyHubs() {
    try {
      cliproxyHubs = await agentApi.cliproxyHubs();
    } catch {
      cliproxyHubs = [];
    }
  }

  async function loadLimits() {
    try {
      accountLimits = await agentApi.limits();
    } catch {
      const fallback: AccountLimits[] = [];
      if (agents.overview?.planUsage) {
        const acc = agents.history?.accounts["claude"];
        fallback.push({
          profileId: "claude",
          kind: "claude",
          name: acc?.name || agentNames.claude,
          email: acc?.name?.includes("@") ? acc.name : null,
          plan: acc?.plan || "",
          apiKey: false,
          usage: agents.overview.planUsage,
          codex: null,
          antigravityLimits: [],
          antigravityNoLogin: false,
          redeeming: false,
        });
      }
      accountLimits = fallback;
    }
  }

  $effect(() => {
    workspace.start();
    let active = true;
    void loadLimits();
    void loadCliProxyHubs();
    void agentApi.usageRefresh(false).catch(() => {});

    const unlisteners: Array<() => void> = [];
    void agentEvents.onUsage(() => { if (active) void loadLimits(); }).then((u) => unlisteners.push(u)).catch(() => {});
    void agentEvents.onCliProxy(() => { if (active) void loadCliProxyHubs(); }).then((u) => unlisteners.push(u)).catch(() => {});
    void agentEvents.onCodexUsage(() => { if (active) void loadLimits(); }).then((u) => unlisteners.push(u)).catch(() => {});
    void agentEvents.onHistory(() => { if (active) void loadLimits(); }).then((u) => unlisteners.push(u)).catch(() => {});

    const tick = setInterval(() => {
      now = new Date();
    }, 60_000);

    return () => {
      active = false;
      clearInterval(tick);
      for (const u of unlisteners) u();
    };
  });

  async function toggleRecap() {
    recapOpen = !recapOpen;
    if (recapOpen && !recap) recap = await services.recap().catch(() => null);
  }

  async function setShowCost(on: boolean) {
    const current = workspace.settings;
    if (current) await workspaceApi.saveSettings({ ...$state.snapshot(current), showCost: on }).catch(() => {});
  }

  async function refreshLimits() {
    refreshing = true;
    try {
      await Promise.all([
        agentApi.usageRefresh(true).catch(() => {}),
        agentApi.cliproxyRefresh(true).catch(() => {}),
      ]);
      await Promise.all([loadLimits(), loadCliProxyHubs(), agents.refresh(), agents.loadHistory(true)]);
      now = new Date();
    } finally {
      refreshing = false;
    }
  }

  const limitLabels = $derived({
    fiveHours: tr("5 uur", "5 hours"),
    week: tr("Week", "Week"),
    startsFirst: tr("Start bij je eerste bericht", "Starts with your first message"),
  });

  function unavailableReason(account: AccountLimitInput): string {
    if (account.apiKey) return tr("Gebruikt een API-sleutel — geen abonnementslimieten.", "Using an API key — no subscription limits.");
    switch (account.kind) {
      case "claude":
        return tr("Niet gelezen — koppel Claude Code in Instellingen › Agents of vernieuw.", "Not read — connect Claude Code in Settings › Agents or refresh.");
      case "codex":
        return tr("Niet gelezen — start Codex een keer of vernieuw.", "Not read — start Codex once or refresh.");
      case "gemini":
        return tr("Gemini CLI meldt geen abonnementslimieten.", "Gemini CLI doesn't report subscription limits.");
      case "antigravity":
        return account.antigravityNoLogin
          ? tr("Niet ingelogd bij Antigravity.", "Not signed in to Antigravity.")
          : tr("Limieten niet beschikbaar.", "Limits not available.");
      default:
        return tr("Deze agent meldt geen abonnementslimieten.", "This agent doesn't report subscription limits.");
    }
  }

  function resetText(limit: LimitDisplay): string | null {
    if (limit.note) return limit.note;
    if (!limit.resetsAt) return null;
    const secs = (limit.resetsAt.getTime() - now.getTime()) / 1000;
    return `↻ ${secs > 0 ? formatCompactDuration(secs) : tr("nu", "now")}`;
  }

  function rowHelp(limit: LimitDisplay): string {
    const used = usedOf(limit.used);
    const lines = [tr("{label}: {used}% gebruikt", "{label}: {used}% used", { label: limit.label, used })];
    if (limit.note) {
      lines.push(limit.note);
    } else if (limit.resetsAt && limit.resetsAt > now) {
      const secs = (limit.resetsAt.getTime() - now.getTime()) / 1000;
      lines.push(
        tr("Reset over {d} · {at}", "Resets in {d} · {at}", {
          d: formatCompactDuration(secs),
          at: formatUpcomingTime(limit.resetsAt, now),
        }),
      );
    }
    const elapsed = timeElapsed(limit, now);
    if (elapsed !== null) {
      lines.push(tr("Venster voor {n}% verstreken", "Window {n}% elapsed", { n: elapsed }));
    }
    const pace = paceForLimit(limit, now);
    if (pace === "ahead") lines.push(tr("Voor op tempo", "Ahead of pace"));
    else if (pace === "on") lines.push(tr("Op tempo", "On pace"));
    else if (pace === "under") lines.push(tr("Onder tempo", "Under pace"));
    return lines.join("\n");
  }

  function creditCountLabel(n: number): string {
    return n === 1
      ? tr("1 reset-tegoed beschikbaar", "1 reset credit available")
      : tr("{n} reset-tegoeden beschikbaar", "{n} reset credits available", { n });
  }

  function creditDetail(acc: AccountLimits): string | null {
    const outcome = creditOutcomes[acc.profileId];
    if (outcome === "reset") return tr("Limieten gereset.", "Limits reset.");
    if (outcome === "nothingToReset") return tr("Niets om te resetten — je limieten zijn al leeg.", "Nothing to reset — your limits are already clear.");
    if (outcome === "noCredit") return tr("Geen reset-tegoed meer over.", "No reset credit left.");
    if (outcome === "alreadyRedeemed") return tr("Dit reset-tegoed is al gebruikt.", "This reset credit was already used.");
    if (outcome === "failed") return tr("Kon het reset-tegoed niet inzetten. Probeer het later opnieuw.", "Couldn't use the reset credit. Try again later.");
    const exp = acc.codex?.resetCredits?.nextExpiresAt;
    if (exp) {
      const secs = (new Date(exp).getTime() - now.getTime()) / 1000;
      if (secs > 0) return tr("Verloopt over {d}", "Expires in {d}", { d: formatCompactDuration(secs) });
    }
    return null;
  }

  async function redeemCredit(acc: AccountLimits) {
    const available = acc.codex?.resetCredits?.available ?? 0;
    if (available <= 0 || redeemingLocal[acc.profileId] || acc.redeeming) return;
    const ok = await ask({
      question: tr("Reset-tegoed gebruiken voor {name}?", "Use a reset credit for {name}?", { name: agentNames[acc.kind] ?? acc.name }),
      detail: tr(
        "Dit maakt je 5-uurs- en weeklimiet direct leeg en verbruikt 1 van je {n} tegoeden.",
        "This clears your 5-hour and weekly limits right away and spends 1 of your {n} credits.",
        { n: available },
      ),
      confirmTitle: tr("Gebruik reset", "Use a reset"),
      destructive: false,
    });
    if (!ok) return;
    redeemingLocal = { ...redeemingLocal, [acc.profileId]: true };
    creditOutcomes = { ...creditOutcomes, [acc.profileId]: null };
    try {
      const key = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
      const outcome = await agentApi.useResetCredit(acc.profileId, key);
      creditOutcomes = { ...creditOutcomes, [acc.profileId]: outcome };
      await loadLimits();
    } catch {
      creditOutcomes = { ...creditOutcomes, [acc.profileId]: "failed" };
    } finally {
      redeemingLocal = { ...redeemingLocal, [acc.profileId]: false };
    }
  }

  async function openExternal(url: string) {
    try {
      await openUrl(url);
    } catch {
      window.open(url, "_blank", "noopener,noreferrer");
    }
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

<div class="sub-head">
  <h3>{tr("Abonnementen", "Subscriptions")}</h3>
  <span class="spacer"></span>
  <button class="ghost-btn" onclick={() => (showLimitsModal = true)}>{tr("Alle limieten", "All limits")}</button>
  <button
    class="icon-btn"
    disabled={refreshing}
    onclick={refreshLimits}
    use:tip={tr("Limieten nu vernieuwen", "Refresh limits now")}
    aria-label={tr("Vernieuwen", "Refresh")}
  >
    <span class:spin={refreshing}><Ico name="refresh-cw" size={14} /></span>
  </button>
</div>
<p class="section-info">
  {tr(
    "Dit is je hele account, niet alleen de werkruimte. Claude, Codex en Antigravity melden hun eigen abonnementslimieten; andere agents melden niets.",
    "This is your whole account, not just the workspace. Claude, Codex and Antigravity report their own subscription limits; other agents report none.",
  )}
</p>

<div class="group subs-list">
  {#each accountLimits as acc (acc.profileId)}
    {@const limits = accountLimitsToPoolLimits(acc, limitLabels, now)}
    {@const groups = groupLimits(limits)}
    {@const page = usagePageUrl(acc.kind)}
    {@const credits = acc.codex?.resetCredits?.available ?? 0}
    {@const outcome = creditOutcomes[acc.profileId]}
    <div class="acct-block">
      <div class="acct-head">
        <AgentMark agent={agentNames[acc.kind] ?? acc.kind} size={16} />
        <span class="acct-name">
          {agentNames[acc.kind] ?? acc.kind}{#if acc.name && acc.name !== agentNames[acc.kind]} <span class="muted">· {acc.name}</span>{/if}
        </span>
        {#if acc.plan}
          <span class="plan-pill">{acc.plan}</span>
        {/if}
        <span class="spacer"></span>
        {#if page}
          <button class="link-btn" onclick={() => openExternal(page)} use:tip={tr("Gebruik beheren", "Manage usage")}>
            <Ico name="arrow-up-right" size={13} />
          </button>
        {/if}
      </div>

      {#if limits.length === 0}
        <div class="limit-row" use:tip={unavailableReason(acc)}>
          <div class="limit-top">
            <span class="limit-label">{tr("Limieten", "Limits")}</span>
            <span class="spacer"></span>
            <span class="limit-unavail">{tr("Niet beschikbaar", "Unavailable")}</span>
          </div>
        </div>
      {:else}
        <div class="limit-groups">
          {#each groups as grp (grp.name)}
            <div class="limit-group">
              {#if grp.name}
                <div class="group-title">{grp.name}</div>
              {/if}
              {#each grp.limits as limit (limit.label)}
                {@const used = usedOf(limit.used)}
                {@const tone = usageTone(used)}
                {@const elapsed = timeElapsed(limit, now)}
                {@const right = resetText(limit)}
                <div class="limit-row" use:tip={rowHelp(limit)}>
                  <div class="limit-top">
                    <span class="limit-label">{grp.name ? limit.window : limit.label}</span>
                    <span class="spacer"></span>
                    <span class="limit-pct {tone}">{used}%</span>
                    {#if right}
                      <span class="limit-reset">{right}</span>
                    {/if}
                  </div>
                  <div class="bar-wrap" aria-hidden="true">
                    <div class="bar-track">
                      <div class="bar-fill {tone}" style:width="{used}%"></div>
                    </div>
                    {#if elapsed !== null}
                      <span class="bar-tick" style:left="clamp(3px, {elapsed}%, calc(100% - 3px))"></span>
                    {/if}
                  </div>
                </div>
              {/each}
            </div>
          {/each}
        </div>
      {/if}

      {#if credits > 0 || outcome != null}
        {@const detail = creditDetail(acc)}
        {@const busy = !!redeemingLocal[acc.profileId] || acc.redeeming}
        <div class="credit-inline">
          <div class="credit-text">
            <div class="credit-title">
              <Ico name="rotate-ccw" size={12} />
              <span>{creditCountLabel(credits)}</span>
            </div>
            {#if detail}
              <div class="credit-detail" class:err={outcome === "failed"}>{detail}</div>
            {/if}
          </div>
          {#if busy}
            <span class="spin"><Ico name="loader-circle" size={14} /></span>
          {:else if credits > 0}
            <button class="ghost-btn" onclick={() => redeemCredit(acc)}>{tr("Gebruik reset", "Use a reset")}</button>
          {/if}
        </div>
      {/if}
    </div>
  {:else}
    <p class="note">{tr("Nog geen accounts met limieten gevonden.", "No accounts with limits found yet.")}</p>
  {/each}
</div>

<SettingsSection
  title={tr("CLIProxyAPI-hubs", "CLIProxyAPI hubs")}
  info={tr(
    "Een CLIProxyAPI-hub bundelt de logins van meerdere accounts achter één adres. Nook leest alleen wat de hub zelf meldt: welke accounts erin zitten, of ze nu requests aannemen, hoe lang een cooldown nog duurt en de limieten die de hub in de headers van zijn laatste requests zag. Nook vraagt de hub nooit om een provider met het token van een account aan te roepen. Zonder requests via de hub zijn er dus nog geen limieten te zien. De beheersleutel staat in de sleutelhanger en gaat alleen naar het adres van de hub.",
    "A CLIProxyAPI hub pools the sign-ins of several accounts behind one address. Nook only reads what the hub itself reports: which accounts are in it, whether they take requests right now, how long a cooldown lasts and the limits the hub saw in the headers of its last requests. Nook never asks the hub to call a provider with an account's token, so no limits show until requests have gone through the hub. The management key stays in the keychain and goes only to the hub's address.",
  )}
>
  <CliProxyHubs hubs={cliproxyHubs} editable={true} {now} onchanged={loadCliProxyHubs} />
</SettingsSection>

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

<TokenSettingsSection />

{#if showLimitsModal}
  <UsageModal initialTab="limits" onclose={() => (showLimitsModal = false)} />
{/if}

<style>
  small {
    font: var(--text-detail);
    line-height: 1.3;
    display: inline-block;
  }
  .spacer {
    flex: 1;
  }
  .sub-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    margin-top: var(--space-24);
  }
  .sub-head h3 {
    margin: 0;
  }
  .ghost-btn {
    padding: var(--space-4) var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: transparent;
    font: var(--text-detail);
    color: var(--text-strong);
    cursor: pointer;
  }
  .ghost-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .icon-btn,
  .link-btn {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    cursor: pointer;
  }
  .icon-btn:hover:not(:disabled),
  .link-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .spin {
    display: inline-flex;
    animation: turn 0.9s linear infinite;
  }
  @keyframes turn {
    to {
      transform: rotate(360deg);
    }
  }
  .subs-list {
    display: flex;
    flex-direction: column;
  }
  .acct-block {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    padding: var(--row-pad-y) var(--row-pad-x);
    border-bottom: 1px solid var(--separator);
  }
  .acct-block:last-child {
    border-bottom: 0;
  }
  .acct-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .acct-name {
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .muted {
    color: var(--text2);
    font-weight: 400;
  }
  .plan-pill {
    padding: var(--space-2) var(--space-6);
    border-radius: var(--radius-chip);
    border: 1px solid var(--line2);
    background: var(--graphite);
    font: var(--text-caption);
    color: var(--text2);
  }
  .limit-groups {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }
  .limit-group {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .group-title {
    font: var(--text-caption);
    font-weight: 600;
    color: var(--text3);
  }
  .limit-row {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .limit-top {
    display: flex;
    align-items: baseline;
    gap: var(--space-8);
  }
  .limit-label {
    font: var(--text-detail);
    color: var(--text2);
  }
  .limit-pct {
    font: var(--text-detail);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: var(--text-strong);
  }
  .limit-pct.warning {
    color: var(--amber);
  }
  .limit-pct.error {
    color: var(--coral-soft);
  }
  .limit-reset {
    font: var(--text-caption);
    font-variant-numeric: tabular-nums;
    color: var(--text3);
    white-space: nowrap;
  }
  .limit-unavail {
    font: var(--text-detail);
    color: var(--text3);
  }
  .bar-wrap {
    position: relative;
    height: 10px;
    display: flex;
    align-items: center;
  }
  .bar-track {
    width: 100%;
    height: 4px;
    border-radius: 999px;
    background: var(--smoke);
    overflow: hidden;
  }
  .bar-fill {
    height: 100%;
    border-radius: 999px;
    background: var(--text2);
    transition: width var(--motion-standard);
  }
  .bar-fill.warning {
    background: var(--amber);
  }
  .bar-fill.error {
    background: var(--coral);
  }
  .bar-tick {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 2px;
    transform: translateX(-1px);
    border-radius: 999px;
    background: var(--paper);
  }
  .credit-inline {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    padding-top: var(--space-8);
    border-top: 1px solid var(--separator);
  }
  .credit-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .credit-title {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    font: var(--text-label);
    color: var(--paper);
  }
  .credit-detail {
    font: var(--text-detail);
    color: var(--text3);
  }
  .credit-detail.err {
    color: var(--coral-soft);
  }
  .report {
    padding: var(--space-12) 0;
  }
</style>
