<script lang="ts">
  // Usage as a modal over the window (1:1 with the Mac's `UsageModal` + `UsageLimitsModal`): Cost, Tokens and Limits tabs,
  // per-agent filter, manual refresh, pooled subscription limit bars with even-pace ticks, clickable account detail popovers,
  // banked Codex reset credits, and unavailable account notices.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import {
    agentApi,
    agentColors,
    agentEvents,
    agentNames,
    formatCompactDuration,
    formatUpcomingTime,
    usagePageUrl,
    type AccountLimits,
    type AgentKind,
    type ResetOutcome,
  } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import type { RunProvider, UsageRange } from "../../lib/workspace/api";
  import {
    buildPoolSections,
    nextRefill,
    timeElapsed,
    usedOf,
    type AccountLimitInput,
    type Limit,
    type Member,
    type Pace,
    type PoolSection,
    type Window as PoolWindow,
  } from "../../lib/workspace/limit-pool";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Dropdown from "../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../components/ui/DropdownRow.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { tip } from "../../components/ui/tip";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import UsagePage from "../workspace/UsagePage.svelte";

  type Tab = "cost" | "tokens" | "limits";
  let { onclose, initialTab }: { onclose: () => void; initialTab?: Tab } = $props();

  const TAB_KEY = "nook.usage.tab";
  const HIDDEN_KEY = "usage.modal.hiddenAgents";

  function loadTab(): Tab {
    if (initialTab) return initialTab;
    try {
      const t = localStorage.getItem(TAB_KEY);
      return t === "cost" || t === "tokens" || t === "limits" ? t : "limits";
    } catch {
      return "limits";
    }
  }

  function loadHidden(): string[] {
    try {
      const raw = localStorage.getItem(HIDDEN_KEY) || "";
      return raw ? raw.split(",").filter(Boolean) : [];
    } catch {
      return [];
    }
  }

  let tab = $state<Tab>(loadTab());
  let range = $state<UsageRange>((localStorage.getItem("ws.usage.range") as UsageRange) || "week");
  let provider = $state<RunProvider | "">("");
  let hiddenList = $state<string[]>(loadHidden());
  let refreshing = $state(false);
  let generation = $state(0);
  let now = $state(new Date());
  let accountLimits = $state<AccountLimits[] | null>(null);

  // Open segment details popover key ("section|window|accountId") and revealed emails.
  let openPopover = $state<string | null>(null);
  let revealedEmails = $state<Record<string, boolean>>({});
  // Per-profile reset credit outcomes and in-flight local guard.
  let creditOutcomes = $state<Record<string, ResetOutcome | null>>({});
  let redeemingLocal = $state<Record<string, boolean>>({});

  function choose(next: Tab) {
    tab = next;
    openPopover = null;
    try {
      localStorage.setItem(TAB_KEY, next);
    } catch {
      /* remembered while the window is open */
    }
  }

  function setHidden(next: string[]) {
    hiddenList = [...new Set(next)].sort();
    try {
      localStorage.setItem(HIDDEN_KEY, hiddenList.join(","));
    } catch {
      /* ignore storage failure */
    }
  }

  function toggleAgentHidden(kind: string) {
    if (hiddenList.includes(kind)) setHidden(hiddenList.filter((k) => k !== kind));
    else setHidden([...hiddenList, kind]);
  }

  async function loadLimits() {
    try {
      accountLimits = await agentApi.limits();
    } catch {
      // Browser/preview fallback: synthesize from already-loaded overview/history.
      const fallback: AccountLimits[] = [];
      const seen = new Set<string>();
      const overview = agents.overview;
      const history = agents.history;
      if (overview?.planUsage) {
        seen.add("claude");
        const acc = history?.accounts["claude"];
        fallback.push({
          profileId: "claude",
          kind: "claude",
          name: acc?.name || agentNames.claude,
          email: acc?.name?.includes("@") ? acc.name : null,
          plan: acc?.plan || "",
          apiKey: false,
          usage: overview.planUsage,
          codex: null,
          antigravityLimits: [],
          antigravityNoLogin: false,
          redeeming: false,
        });
      }
      for (const [id, usage] of Object.entries(overview?.profilePlanUsage ?? {})) {
        if (seen.has(id)) continue;
        seen.add(id);
        const acc = history?.accounts[id];
        fallback.push({
          profileId: id,
          kind: "claude",
          name: acc?.name || id,
          email: acc?.name?.includes("@") ? acc.name : null,
          plan: acc?.plan || "",
          apiKey: false,
          usage,
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
    let active = true;
    void loadLimits();
    void agentApi.usageRefresh(false).catch(() => {});

    const unlisteners: Array<() => void> = [];
    void agentEvents.onUsage(() => { if (active) void loadLimits(); }).then((u) => unlisteners.push(u)).catch(() => {});
    void agentEvents.onCodexUsage(() => { if (active) void loadLimits(); }).then((u) => unlisteners.push(u)).catch(() => {});
    void agentEvents.onHistory(() => { if (active) void loadLimits(); }).then((u) => unlisteners.push(u)).catch(() => {});

    const tick = setInterval(() => {
      now = new Date();
    }, 60_000);
    const poll = setInterval(() => {
      void agentApi.usageRefresh(false).catch(() => {});
    }, 120_000);

    return () => {
      active = false;
      clearInterval(tick);
      clearInterval(poll);
      for (const u of unlisteners) u();
    };
  });

  async function refresh() {
    refreshing = true;
    try {
      await agentApi.usageRefresh(true).catch(() => {});
      await Promise.all([loadLimits(), agents.refresh(), agents.loadHistory(true), workspace.refresh()]);
      now = new Date();
      generation++;
    } finally {
      refreshing = false;
    }
  }

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

  const limitLabels = $derived({
    fiveHours: tr("5 uur", "5 hours"),
    week: tr("Week", "Week"),
    startsFirst: tr("Start bij je eerste bericht", "Starts with your first message"),
  });

  const hiddenSet = $derived(new Set(hiddenList));

  const built = $derived.by(() =>
    buildPoolSections(accountLimits ?? [], {
      now,
      hidden: hiddenSet,
      labels: limitLabels,
      agentName: (k) => agentNames[k as AgentKind] ?? k,
      unavailableReason,
      formatNotice: (title, reason) => tr("{account}: {reason}", "{account}: {reason}", { account: title, reason }),
    }),
  );

  const filterableKinds = $derived.by(() => {
    const present = new Set<AgentKind>();
    for (const a of accountLimits ?? []) present.add(a.kind);
    for (const k of hiddenList) present.add(k as AgentKind);
    const order: AgentKind[] = ["claude", "codex", "gemini", "antigravity", "opencode", "cursor", "grok"];
    return order.filter((k) => present.has(k));
  });

  const creditHolders = $derived(
    (accountLimits ?? []).filter(
      (a) => !hiddenSet.has(a.kind) && ((a.codex?.resetCredits?.available ?? 0) > 0 || creditOutcomes[a.profileId] != null),
    ),
  );

  const tabs = $derived<[Tab, string][]>([
    ["cost", tr("Kosten", "Cost")],
    ["tokens", tr("Tokens", "Tokens")],
    ["limits", tr("Limieten", "Limits")],
  ]);
  const ranges = $derived<[UsageRange, string][]>([
    ["today", tr("Vandaag", "Today")],
    ["week", tr("7 dagen", "7 days")],
    ["month", tr("30 dagen", "30 days")],
    ["all", tr("Alles", "All")],
  ]);
  const filtered = $derived(tab === "limits" ? hiddenList.length > 0 : provider !== "" || range !== "week");

  function paceTooltip(pace: Pace): string {
    if (pace === "ahead") return tr("Sneller dan gelijkmatig verbruik over dit venster", "Spending faster than an even pace across this window");
    if (pace === "under") return tr("Langzamer dan gelijkmatig verbruik over dit venster", "Spending slower than an even pace across this window");
    return tr("Op tempo voor gelijkmatig verbruik over dit venster", "On track for an even pace across this window");
  }

  function resetChipLabel(limit: Limit): string | null {
    if (!limit.resetsAt) return null;
    const secs = (limit.resetsAt.getTime() - now.getTime()) / 1000;
    return secs > 0 ? formatCompactDuration(secs) : tr("nu", "now");
  }

  function segmentFillStyle(member: Member, window: PoolWindow): { solidPct: number; hatchStart: number; hatchPct: number } {
    if (!member.limit) return { solidPct: 0, hatchStart: 0, hatchPct: 0 };
    const used = usedOf(member.limit.used);
    const reset = window.resets.find((r) => r.accountId === member.accountId);
    const freed = reset ? Math.min(member.limit.used, member.refill) : 0;
    const partial = freed > 0 && member.limit.used - freed >= 0.5;
    const hatched = partial ? Math.min(freed, used) : 0;
    const solid = Math.max(0, used - hatched);
    return { solidPct: solid, hatchStart: solid, hatchPct: hatched };
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

  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      if (openPopover) {
        openPopover = null;
        return;
      }
      onclose();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey) {
      if (e.key === "1") { e.preventDefault(); choose("cost"); }
      else if (e.key === "2") { e.preventDefault(); choose("tokens"); }
      else if (e.key === "3") { e.preventDefault(); choose("limits"); }
    }
  }
</script>

<svelte:window onkeydown={keys} />

<div class="backdrop" role="presentation" onclick={onclose}>
  <div
    class="sheet"
    role="dialog"
    aria-modal="true"
    aria-label={tr("Gebruik", "Usage")}
    tabindex="-1"
    onclick={(e) => {
      e.stopPropagation();
      openPopover = null;
    }}
    onkeydown={() => {}}
  >
    <header>
      <h2>{tr("Gebruik", "Usage")}</h2>
      <span class="spacer"></span>
      <div class="segments" role="tablist">
        {#each tabs as [t, label] (t)}
          <button role="tab" aria-selected={tab === t} class:on={tab === t} onclick={() => choose(t)}>{label}</button>
        {/each}
      </div>
      <Dropdown width={240} below align="right" label={tr("Filter", "Filter")}>
        {#snippet trigger({ toggle, open })}
          <button
            class="icon"
            class:on={open || filtered}
            onclick={toggle}
            aria-expanded={open}
            use:tip={tr("Filter", "Filter")}
            aria-label={tr("Filter", "Filter")}
          >
            <Ico name="list-filter" size={16} />
          </button>
        {/snippet}
        {#snippet children()}
          {#if tab === "limits"}
            <div class="dd-header">{tr("Agents", "Agents")}</div>
            {#each filterableKinds as kind (kind)}
              {@const shown = !hiddenSet.has(kind)}
              <DropdownRow
                brand={agentNames[kind]}
                title={agentNames[kind]}
                chosen={shown}
                trailing={shown ? "✓" : undefined}
                onclick={() => toggleAgentHidden(kind)}
              />
            {/each}
            {#if hiddenList.length > 0}
              <DropdownRow
                symbol="eye"
                title={tr("Alle agents tonen", "Show all agents")}
                onclick={() => setHidden([])}
              />
            {/if}
          {:else}
            <div class="dd-header">{tr("Agent", "Agent")}</div>
            <DropdownRow title={tr("Alle agents", "All agents")} chosen={provider === ""} trailing={provider === "" ? "✓" : undefined} onclick={() => (provider = "")} />
            {#each workspace.providers.filter((p) => p.supported) as p (p.provider)}
              <DropdownRow brand={p.name} title={p.name} chosen={provider === p.provider} trailing={provider === p.provider ? "✓" : undefined} onclick={() => (provider = p.provider)} />
            {/each}
            <div class="dd-header">{tr("Periode", "Period")}</div>
            {#each ranges as [r, label] (r)}
              <DropdownRow title={label} chosen={range === r} trailing={range === r ? "✓" : undefined} onclick={() => (range = r)} />
            {/each}
          {/if}
        {/snippet}
      </Dropdown>
      <button
        class="icon"
        disabled={refreshing}
        onclick={refresh}
        use:tip={tr("Limieten nu vernieuwen", "Refresh limits now")}
        aria-label={tr("Vernieuwen", "Refresh")}
      >
        <span class:spin={refreshing}><Ico name="refresh-cw" size={15} /></span>
      </button>
      <button class="icon" onclick={onclose} use:tip={tr("Sluit", "Close")} aria-label={tr("Sluit", "Close")}>
        <Ico name="x" size={16} />
      </button>
    </header>

    <div class="body">
      {#if tab === "limits"}
        <div class="limits-scroll">
          {#if built.sections.length === 0 && built.notices.length === 0}
            <p class="empty-note">{tr("Nog geen limieten — ze verschijnen zodra een agent ze meldt.", "No limits yet — they appear once an agent reports them.")}</p>
          {/if}

          {#each built.sections as section (section.kind)}
            {@const kind = section.kind as AgentKind}
            {@const page = usagePageUrl(kind)}
            <section class="pool-section" style:--agent-color={agentColors[kind] ?? agentColors.claude}>
              <div class="section-head">
                <AgentMark agent={agentNames[kind] ?? kind} size={18} />
                <h3>{agentNames[kind] ?? kind}</h3>
                <span class="spacer"></span>
                {#if page}
                  <button class="manage-btn" onclick={() => openExternal(page)}>
                    <span>{tr("Gebruik beheren", "Manage usage")}</span>
                    <Ico name="arrow-up-right" size={12} />
                  </button>
                {/if}
              </div>

              {#each section.pool.windows as win (win.label)}
                {@const refill = win.columns.length > 1 ? nextRefill(win) : null}
                <div class="win-card">
                  <div class="win-summary">
                    <div class="win-label">{win.label}</div>
                    <div class="win-figure">
                      <span class="win-pct">{win.used}%</span>
                      <span class="win-word">{tr("gebruikt", "used")}</span>
                      {#if win.pace}
                        <span class="pace-icon" class:under={win.pace === "under"} use:tip={paceTooltip(win.pace)} aria-label={paceTooltip(win.pace)}>
                          <Ico name={win.pace === "on" ? "gauge" : "trending-up"} size={13} />
                        </span>
                      {/if}
                    </div>
                    {#if refill}
                      <div class="win-refill">↻ −{refill.restores}%</div>
                    {/if}
                  </div>

                  <div class="pool-bar">
                    {#each win.columns as member (member.accountId)}
                      {@const segId = `${section.kind}|${win.label}|${member.accountId}`}
                      {@const isOpen = openPopover === segId}
                      {#if member.limit}
                        {@const used = usedOf(member.limit.used)}
                        {@const elapsed = timeElapsed(member.limit, now)}
                        {@const fill = segmentFillStyle(member, win)}
                        {@const resetsIn = resetChipLabel(member.limit)}
                        {@const details = section.details[member.accountId]}
                        {@const credits = details?.credits ?? 0}
                        {@const reset = win.resets.find((r) => r.accountId === member.accountId)}
                        <div class="seg-wrap">
                          <button
                            class="seg"
                            class:open={isOpen}
                            onclick={(e) => {
                              e.stopPropagation();
                              openPopover = isOpen ? null : segId;
                            }}
                          >
                            <span class="seg-track" aria-hidden="true">
                              {#if fill.solidPct > 0}
                                <span class="seg-fill" style:width="{fill.solidPct}%"></span>
                              {/if}
                              {#if fill.hatchPct > 0}
                                <span class="seg-hatch" style:left="{fill.hatchStart}%" style:width="{fill.hatchPct}%"></span>
                              {/if}
                              {#if elapsed !== null}
                                <span class="seg-pace" style:left="clamp(3px, {elapsed}%, calc(100% - 3px))"></span>
                              {/if}
                            </span>

                            <span class="seg-overlay">
                              {#if win.columns.length > 1}
                                <span class="seg-name">{member.name}</span>
                                <span class="seg-used">{used}%</span>
                              {/if}
                              <span class="spacer"></span>
                              {#if resetsIn || credits > 0}
                                <span class="reset-chip">
                                  {#if resetsIn}<span>↻ {resetsIn}</span>{/if}
                                  {#if resetsIn && credits > 0}<span class="dot">·</span>{/if}
                                  {#if credits > 0}
                                    <span class="chip-credits">
                                      <Ico name="sparkles" size={11} />
                                      <span>{credits}</span>
                                    </span>
                                  {/if}
                                </span>
                              {/if}
                            </span>
                          </button>

                          {#if isOpen}
                            <div class="seg-popover" role="dialog" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
                              <div class="pop-head">
                                <div class="pop-title">
                                  <AgentMark agent={agentNames[kind] ?? kind} size={16} />
                                  <span>{member.name}</span>
                                </div>
                                {#if details?.email}
                                  {@const shownEmail = !!revealedEmails[member.accountId]}
                                  <button
                                    class="email-reveal"
                                    class:blurred={!shownEmail}
                                    onclick={() => (revealedEmails = { ...revealedEmails, [member.accountId]: !shownEmail })}
                                    use:tip={shownEmail ? tr("Klik om te verbergen", "Click to hide") : tr("Klik om te tonen", "Click to reveal")}
                                  >
                                    {details.email}
                                  </button>
                                {/if}
                              </div>

                              {#if details?.plan}
                                <div class="pop-group">
                                  <div class="pop-row">
                                    <span class="pop-k">{tr("Abonnement", "Plan")}</span>
                                    <span class="pop-v">{details.plan}</span>
                                  </div>
                                </div>
                              {/if}

                              <div class="pop-group">
                                <div class="pop-row">
                                  <span class="pop-k">{tr("Gebruikt", "Used")}</span>
                                  <span class="pop-v">{used}%</span>
                                </div>
                                {#if member.limit.resetsAt}
                                  {@const secs = (member.limit.resetsAt.getTime() - now.getTime()) / 1000}
                                  <div class="pop-row">
                                    <span class="pop-k">{tr("Reset", "Resets")}</span>
                                    <span class="pop-v">
                                      {#if secs > 0}
                                        {formatUpcomingTime(member.limit.resetsAt, now)} · {tr("over {d}", "in {d}", { d: formatCompactDuration(secs) })}
                                      {:else}
                                        {tr("nu", "now")}
                                      {/if}
                                    </span>
                                  </div>
                                {/if}
                                {#if elapsed !== null}
                                  <div class="pop-row">
                                    <span class="pop-k">{tr("Op tempo", "Even pace")}</span>
                                    <span class="pop-v">{tr("{n}% tot nu toe", "{n}% by now", { n: elapsed })}</span>
                                  </div>
                                {/if}
                                {#if reset && reset.restores > 0 && win.columns.length > 1}
                                  <div class="pop-row">
                                    <span class="pop-k">{tr("Geeft terug", "Restores")}</span>
                                    <span class="pop-v">{tr("{n}% van de pool", "{n}% of the pool", { n: reset.restores })}</span>
                                  </div>
                                {/if}
                              </div>

                              {#if elapsed !== null}
                                <p class="pop-foot">{tr("Het streepje geeft gelijkmatig verbruik over het venster aan.", "The line marks even spending across the window.")}</p>
                              {/if}
                            </div>
                          {/if}
                        </div>
                      {:else}
                        <div class="seg-gap" aria-hidden="true"></div>
                      {/if}
                    {/each}
                  </div>
                </div>
              {/each}
            </section>
          {/each}

          {#if creditHolders.length > 0}
            <div class="credits-list">
              {#each creditHolders as acc (acc.profileId)}
                {@const available = acc.codex?.resetCredits?.available ?? 0}
                {@const detail = creditDetail(acc)}
                {@const busy = !!redeemingLocal[acc.profileId] || acc.redeeming}
                <div class="credit-row">
                  <AgentMark agent={agentNames[acc.kind] ?? acc.kind} size={16} />
                  <div class="credit-text">
                    <div class="credit-title">
                      <Ico name="rotate-ccw" size={12} />
                      <span>{creditCountLabel(available)}</span>
                      {#if acc.name && acc.name !== agentNames[acc.kind]}
                        <span class="credit-acct">· {acc.name}</span>
                      {/if}
                    </div>
                    {#if detail}
                      <div class="credit-detail" class:err={creditOutcomes[acc.profileId] === "failed"}>{detail}</div>
                    {/if}
                  </div>
                  {#if busy}
                    <span class="credit-spin"><Ico name="loader-circle" size={15} /></span>
                  {:else if available > 0}
                    <button class="ghost-btn" onclick={() => redeemCredit(acc)}>{tr("Gebruik reset", "Use a reset")}</button>
                  {/if}
                </div>
              {/each}
            </div>
          {/if}

          {#if built.notices.length > 0}
            <div class="notices">
              <span class="notice-ico"><Ico name="triangle-alert" size={14} /></span>
              <div class="notice-lines">
                {#each built.notices as line (line)}
                  <div>{line}</div>
                {/each}
              </div>
            </div>
          {/if}
        </div>
      {:else}
        {#key `${tab}:${generation}`}
          <UsagePage part={tab} controls={false} bind:range bind:provider />
        {/key}
      {/if}
    </div>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 80;
    display: grid;
    place-items: center;
    padding: var(--space-24);
    background: color-mix(in srgb, var(--canvas) 55%, transparent);
  }
  .sheet {
    display: flex;
    flex-direction: column;
    width: min(720px, 100%);
    height: min(560px, 100%);
    min-height: 0;
    background: var(--surface);
    border: 1px solid var(--line2);
    border-radius: var(--radius-sheet);
    box-shadow: var(--shadow-popover);
    overflow: hidden;
  }
  header {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-12) var(--space-24);
    border-bottom: 1px solid var(--line);
  }
  h2 {
    margin: 0;
    font: var(--text-heading);
    color: var(--paper);
  }
  .spacer {
    flex: 1;
  }
  .segments {
    display: inline-flex;
    gap: var(--space-2);
    padding: var(--space-2);
    margin-right: var(--space-8);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: var(--graphite);
  }
  .segments button {
    height: 26px;
    margin: 0;
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    font: var(--text-control);
    font-weight: 400;
    color: var(--text2);
  }
  .segments button:hover {
    color: var(--paper);
    background: transparent;
  }
  .segments button.on {
    background: var(--smoke);
    color: var(--paper);
    font-weight: 600;
  }
  .icon {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
  }
  .icon:hover:not(:disabled),
  .icon.on {
    background: var(--smoke);
    color: var(--paper);
  }
  .spin,
  .credit-spin {
    display: inline-flex;
    animation: turn 0.9s linear infinite;
  }
  @keyframes turn {
    to {
      transform: rotate(360deg);
    }
  }
  .body {
    flex: 1;
    min-height: 0;
    overflow: hidden;
    padding: var(--space-16) var(--space-24);
    display: flex;
    flex-direction: column;
  }
  .limits-scroll {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: var(--space-24);
    padding-bottom: var(--space-16);
  }
  .empty-note {
    margin: 0;
    font: var(--text-body);
    color: var(--text2);
  }
  .pool-section {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }
  .section-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .section-head h3 {
    margin: 0;
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .manage-btn,
  .ghost-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    padding: var(--space-4) var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: transparent;
    font: var(--text-detail);
    color: var(--text-strong);
    cursor: pointer;
  }
  .manage-btn:hover,
  .ghost-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .win-card {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-16);
    padding: var(--space-16);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: transparent;
  }
  .win-summary {
    flex: 0 0 168px;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .win-label {
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .win-figure {
    display: flex;
    align-items: baseline;
    gap: var(--space-8);
  }
  .win-pct {
    font: var(--text-display);
    font-variant-numeric: tabular-nums;
    color: var(--paper);
  }
  .win-word {
    font: var(--text-body);
    color: var(--text2);
  }
  .pace-icon {
    display: inline-flex;
    align-items: center;
    color: var(--text2);
  }
  .pace-icon.under {
    transform: scaleY(-1);
  }
  .win-refill {
    font: var(--text-label);
    font-variant-numeric: tabular-nums;
    color: var(--paper);
  }
  .pool-bar {
    flex: 1 1 280px;
    display: flex;
    gap: var(--space-4);
    min-width: 0;
  }
  .seg-wrap {
    flex: 1 1 0;
    position: relative;
    min-width: 0;
  }
  .seg-gap {
    flex: 1 1 0;
    height: 32px;
  }
  .seg {
    position: relative;
    display: flex;
    align-items: center;
    width: 100%;
    height: 32px;
    padding: 0;
    margin: 0;
    border: 1px solid transparent;
    border-radius: var(--radius-chip);
    background: color-mix(in srgb, var(--paper) 5%, transparent);
    overflow: hidden;
    cursor: pointer;
    text-align: left;
  }
  .seg:hover,
  .seg.open {
    border-color: var(--line2);
  }
  .seg-track {
    position: absolute;
    inset: 0;
    pointer-events: none;
  }
  .seg-fill {
    position: absolute;
    top: 0;
    bottom: 0;
    left: 0;
    background: color-mix(in srgb, var(--agent-color) 35%, transparent);
  }
  .seg-hatch {
    position: absolute;
    top: 0;
    bottom: 0;
    background-image: repeating-linear-gradient(
      -45deg,
      color-mix(in srgb, var(--agent-color) 45%, transparent) 0 2px,
      transparent 2px 6px
    );
  }
  .seg-pace {
    position: absolute;
    top: 2px;
    bottom: 2px;
    width: 2px;
    transform: translateX(-1px);
    border-radius: 999px;
    background: var(--paper);
    box-shadow: 0 0 0 2px var(--surface);
  }
  .seg-overlay {
    position: relative;
    z-index: 1;
    display: flex;
    align-items: center;
    gap: var(--space-6);
    width: 100%;
    padding: 0 var(--space-8);
    min-width: 0;
  }
  .seg-name {
    font: var(--text-detail);
    font-weight: 500;
    color: var(--paper);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .seg-used {
    font: var(--text-detail);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: var(--paper);
    flex-shrink: 0;
  }
  .reset-chip {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    padding: var(--space-2) var(--space-6);
    border-radius: var(--radius-chip);
    background: color-mix(in srgb, var(--canvas) 85%, transparent);
    font: var(--text-caption);
    font-variant-numeric: tabular-nums;
    color: var(--paper);
    white-space: nowrap;
    flex-shrink: 0;
  }
  .reset-chip .dot {
    color: var(--text2);
  }
  .chip-credits {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    font-weight: 600;
  }
  .seg-popover {
    position: absolute;
    top: calc(100% + var(--space-6));
    right: 0;
    z-index: 20;
    width: 288px;
    padding: var(--space-16);
    background: var(--menu);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    box-shadow: var(--shadow-popover);
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    font: var(--text-detail);
  }
  .pop-head {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .pop-title {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .email-reveal {
    align-self: flex-start;
    padding: 0;
    margin: 0;
    border: 0;
    background: transparent;
    font: var(--text-detail);
    color: var(--text2);
    cursor: pointer;
    transition: filter var(--motion-quick);
  }
  .email-reveal.blurred {
    filter: blur(4px);
  }
  .pop-group {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    padding-top: var(--space-8);
    border-top: 1px solid var(--separator);
  }
  .pop-row {
    display: flex;
    align-items: baseline;
    gap: var(--space-12);
  }
  .pop-k {
    flex: 0 0 76px;
    color: var(--text2);
  }
  .pop-v {
    color: var(--paper);
    font-variant-numeric: tabular-nums;
  }
  .pop-foot {
    margin: 0;
    font: var(--text-detail);
    color: var(--text2);
  }
  .credits-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .credit-row {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    padding: var(--space-12) var(--space-16);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--well);
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
  .credit-acct {
    color: var(--text2);
    font-weight: 400;
  }
  .credit-detail {
    font: var(--text-detail);
    color: var(--text3);
  }
  .credit-detail.err {
    color: var(--coral-soft);
  }
  .notices {
    display: flex;
    align-items: flex-start;
    gap: var(--space-12);
    padding: var(--space-12) var(--space-16);
    border-radius: var(--radius-card);
    border: 1px solid color-mix(in srgb, var(--amber) 30%, transparent);
    background: color-mix(in srgb, var(--amber) 8%, transparent);
    font: var(--text-detail);
    color: var(--paper);
  }
  .notice-ico {
    display: inline-flex;
    color: var(--amber);
    margin-top: var(--space-2);
  }
  .notice-lines {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
</style>
