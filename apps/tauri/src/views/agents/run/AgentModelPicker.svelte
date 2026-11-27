<script lang="ts">
  // The agent pill of a session composer and the picker behind it (the Mac's `ComposerPill` with `AgentModelPicker` in
  // `ModelPickerDropdown`): the pill shows the agent's logo and its model; the panel uses the shared
  // `ModelPickerDropdown` (rail of agents/accounts, search and models) plus the thinking-effort column
  // (`ModelPickerReasoning`) and the options footer (`ModelPickerOptions`). Both the new-session composer and a
  // running session's composer use this one view.
  import { api } from "../../../lib/api";
  import type { AgentProfile } from "../../../lib/agents";
  import { accountCustomModels, pickableProfiles } from "../../../lib/account-options";
  import { tr } from "../../../lib/i18n.svelte";
  import {
    effortLabels, effortLevels, permissionHelp, permissionLabels, type ExecutionMode, type PermissionPolicy, type ProviderInfo, type RunProvider,
  } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { catalog, compactModelName } from "../../../lib/workspace/models.svelte";
  import type { ModelPickerItem, ModelPickerList, ModelPickerPlace } from "../../../lib/model-picker";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import ModelPickerDropdown from "../../../components/ui/ModelPickerDropdown.svelte";
  import AgentMark from "../../companion/ui/AgentMark.svelte";

  let {
    providers, profiles, provider, profileId, model, mode, permission, effort, disabled = false, note, title,
    onchoose, onmode, onpermission, oneffort,
  }: {
    /** The agents to offer, in the rail's order. */
    providers: ProviderInfo[];
    profiles: AgentProfile[];
    provider: RunProvider;
    profileId: string;
    model: string;
    mode: ExecutionMode;
    permission: PermissionPolicy;
    effort: string | null;
    disabled?: boolean;
    /** A line over the footer, such as what picking another agent does while this one works. */
    note?: string;
    /** The pill's tooltip. */
    title?: string;
    onchoose: (provider: RunProvider, profileId: string, model: string) => void;
    onmode?: (mode: ExecutionMode) => void;
    onpermission: (policy: PermissionPolicy) => void;
    oneffort: (level: string | null) => void;
  } = $props();

  interface PlaceEntry { id: string; provider: ProviderInfo; profile: AgentProfile | null }

  let open = $state(false);
  let hovered = $state<PermissionPolicy | null>(null);

  const visibleProfiles = $derived(pickableProfiles(profiles, profileId));
  const own = (p: RunProvider) => visibleProfiles.filter((x) => x.kind === p);
  const placeEntries = $derived<PlaceEntry[]>(providers.flatMap((p) => {
    const allForKind = profiles.filter((x) => x.kind === p.provider);
    const accounts = own(p.provider);
    // If every configured account for this agent was explicitly switched off, omit it from the rail.
    if (allForKind.length > 0 && accounts.length === 0) return [];
    return accounts.length > 1
      ? accounts.map((a) => ({ id: `${p.provider}/${a.id}`, provider: p, profile: a }))
      : [{ id: p.provider, provider: p, profile: accounts[0] ?? null }];
  }));
  const pickerPlaces = $derived<ModelPickerPlace[]>(placeEntries.map((entry) => ({
    id: entry.id,
    name: entry.provider.name,
    detail: !entry.provider.executable
      ? tr("{agent} staat niet op deze computer.", "{agent} isn't installed on this computer.", { agent: entry.provider.name })
      : entry.profile?.label
        ? entry.profile.label
        : tr("Met je eigen aanmelding bij {agent}.", "With your own sign-in to {agent}.", { agent: entry.provider.name }),
    help: entry.profile?.label ? `${entry.provider.name} · ${entry.profile.label}` : entry.provider.name,
    dimmed: !entry.provider.executable,
  })));
  const chosenId = $derived(own(provider).length > 1 ? `${provider}/${profileId}` : provider);
  const info = $derived(providers.find((p) => p.provider === provider) ?? workspace.provider(provider));
  const agentName = $derived(info?.name ?? provider);
  const account = $derived(own(provider).length > 1 ? own(provider).find((a) => a.id === profileId) : undefined);
  const caps = $derived(info?.capabilities);
  const levels = $derived(effortLevels(provider));
  const policies = $derived<PermissionPolicy[]>(caps?.policies ?? ["acceptEdits"]);
  const readOnly = $derived(mode === "plan");

  /** The models this agent was used with here (your defaults, per-folder choices, other sessions), newest choice first. */
  function knownModels(p: RunProvider): string[] {
    const s = workspace.settings;
    const out = [
      p === provider ? model : "",
      s?.defaultModels[p] ?? "",
      ...Object.values(s?.folderChoices ?? {}).map((f) => f.agents[p]?.model ?? ""),
      ...workspace.runs.filter((r) => r.provider === p).map((r) => r.model),
    ];
    return [...new Set(out.map((m) => m.trim()).filter(Boolean))];
  }

  function pick(entry: PlaceEntry, chosenModel: string) {
    const p = entry.provider.provider;
    const pickedAccount = entry.profile?.id ?? (p === provider ? profileId : (own(p).find((a) => a.preferred) ?? own(p)[0])?.id ?? p);
    onchoose(p, pickedAccount, chosenModel);
  }

  function listFor(place: ModelPickerPlace, query: string): ModelPickerList {
    const entry = placeEntries.find((e) => e.id === place.id);
    if (!entry) return { models: [] };
    const p = entry.provider.provider;
    const q = query.trim();
    const listed = catalog.byAgent[p] ?? [];
    const custom = accountCustomModels(entry.profile).filter((m) => !catalog.find(p, m));
    const customSet = new Set(custom);
    const known = knownModels(p).filter((m) => !catalog.find(p, m) && !customSet.has(m));
    const chosenLegacy = listed.filter((m) => !m.current && p === provider && catalog.find(p, model)?.id === m.id);
    const isChosen = (m: string) =>
      entry.id === chosenId && (m === model || (!!m && catalog.find(provider, model)?.id === m));

    const candidates: { id: string; title: string; trailing?: string; model: string }[] = [
      { id: "", title: tr("Standaard", "Default"), trailing: tr("van de agent", "the agent's own"), model: "" },
      ...[...listed.filter((m) => m.current), ...chosenLegacy].map((m) => ({
        id: m.id,
        title: m.name,
        trailing: m.isNew ? tr("Nieuw", "New") : undefined,
        model: m.id,
      })),
      ...custom.map((m) => ({ id: m, title: m, model: m })),
      ...known.map((m) => ({ id: m, title: m, model: m })),
    ];
    const modelRows: ModelPickerItem[] = candidates
      .filter((r) => !q || `${r.title} ${r.model}`.toLowerCase().includes(q.toLowerCase()))
      .map((r) => ({
        id: r.id,
        brand: entry.provider.name,
        title: r.title,
        trailing: r.trailing,
        chosen: isChosen(r.model),
        onpick: () => pick(entry, r.model),
      }));

    // Any model name the agent accepts: typed in the search, it becomes an action row of its own.
    const actions: ModelPickerItem[] = [];
    if (q && !modelRows.some((r) => r.id === q) && !catalog.find(p, q)) {
      actions.push({
        id: `use:${q}`,
        brand: entry.provider.name,
        title: tr("Gebruik “{model}”", "Use “{model}”", { model: q }),
        onpick: () => pick(entry, q),
      });
    }
    return { models: modelRows, actions };
  }

  function openSettings() {
    try { localStorage.setItem("settings.section", "agents"); } catch { /* opens on the last page instead */ }
    api.showMain("settings");
  }

  const pillText = $derived(model ? compactModelName(catalog.find(provider, model)?.name ?? model, agentName) : agentName);
  $effect(() => catalog.load());
  const effortWord = $derived(effort ? (effortLabels[effort] ?? effort) : "");
  /// The access levels as the Mac draws them (`PermissionPolicy.symbol`).
  const accessSymbol = (p: PermissionPolicy) => (p === "bypass" ? "lock-open" : p === "ask" ? "lock" : "pencil");

  // The access panel opens over the picker's footer. It is placed on the page itself (fixed), because the picker's
  // panel scrolls and would cut off a panel inside it.
  let accessAt = $state<{ right: number; bottom: number } | null>(null);
  function toggleAccess(e: MouseEvent) {
    if (accessAt) { accessAt = null; return; }
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    accessAt = { right: window.innerWidth - r.right, bottom: window.innerHeight - r.top + 6 };
  }
  $effect(() => { if (!open) accessAt = null; });

  // Ctrl+Shift+M (and E, A) from the Agents tab open this picker; A opens its access panel too.
  let anchor = $state<HTMLSpanElement>();
  $effect(() => {
    const on = (e: Event) => {
      if (disabled || !anchor?.parentElement?.offsetParent) return;
      if (!open) open = true;
      if ((e as CustomEvent<string>).detail === "access") {
        requestAnimationFrame(() => anchor?.parentElement?.querySelector<HTMLButtonElement>(".access-pill")?.click());
      }
    };
    window.addEventListener("nook-agents-picker", on);
    return () => window.removeEventListener("nook-agents-picker", on);
  });
</script>

<span class="anchor" bind:this={anchor}></span>
<ModelPickerDropdown
  bind:open
  places={pickerPlaces}
  {chosenId}
  list={listFor}
  hasSideColumn={levels.length > 0}
  addHelp={tr("Een agent toevoegen in Instellingen › Coding-agents", "Add an agent in Settings › Coding agents")}
  onadd={openSettings}
  label={tr("Agent en model kiezen", "Choose the agent and model")}
>
  {#snippet trigger({ toggle, open })}
    <button class="agent-pill" onclick={toggle} {disabled} aria-expanded={open} title={title ?? agentName}
      aria-label={tr("Agent en model", "Agent and model")}>
      <AgentMark agent={agentName} size={15} />
      <span class="text">{pillText}{#if account?.label}<span class="detail"> · {account.label}</span>{/if}</span>{#if effortWord}<span class="effort">{effortWord}</span>{/if}
    </button>
  {/snippet}
  {#snippet trailing()}
    <div class="side-head"><span>{tr("Denkniveau", "Thinking effort")}</span><span class="side-model">{model || agentName}</span></div>
    <DropdownRow symbol="circle-dashed" title={effortLabels[""]} trailing={!effort ? "✓" : undefined} chosen={!effort} onclick={() => oneffort(null)} />
    {#each levels as l (l)}
      <DropdownRow symbol="gauge" title={effortLabels[l] ?? l} trailing={effort === l ? "✓" : undefined} chosen={effort === l} onclick={() => oneffort(l)} />
    {/each}
  {/snippet}
  {#snippet footer()}
    {#if note}<p class="note"><Ico name="circle-stop" size={13} />{note}</p>{/if}
    <div class="option-row">
      {#if onmode && caps?.planMode !== false}
        <div class="segments" role="group" aria-label={tr("Modus", "Mode")}>
          <button class:on={mode === "agent"} onclick={() => onmode?.("agent")} title={tr("De agent mag werken in de map, binnen de rechten hieronder.", "The agent may work in the folder, within the permissions below.")}><Ico name="hammer" size={14} />{tr("Agent", "Agent")}</button>
          <button class:on={mode === "plan"} onclick={() => onmode?.("plan")} title={tr("Alleen lezen en een plan maken; er wordt niets aangepast.", "Only read and make a plan; nothing is changed.")}><Ico name="list-checks" size={14} />{tr("Plan", "Plan")}</button>
        </div>
      {/if}
      <span class="grow"></span>
      <button class="agent-pill access-pill" class:hot={permission === "bypass" && !readOnly} disabled={readOnly} onclick={toggleAccess} aria-expanded={!!accessAt}
        title={readOnly ? tr("In Plan-modus leest de agent alleen.", "In Plan mode the agent only reads.") : permissionHelp(permission, provider)}>
        <Ico name={readOnly ? "lock" : accessSymbol(permission)} size={15} /><span class="text">{readOnly ? tr("Alleen lezen", "Read only") : permissionLabels[permission]}</span><Ico name="chevron-down" size={10} stroke={2.5} />
      </button>
    </div>
    {#if accessAt}
      <!-- `ModelPickerPermissions`: the levels as icons on smoke, then the one under the pointer (or the chosen one) in words. -->
      <div class="access-pop" style:right="{accessAt.right}px" style:bottom="{accessAt.bottom}px" role="dialog" aria-label={tr("Toegang", "Access")}>
        <span class="access-head">{tr("Toegang", "Access")}</span>
        <div class="segments wide" role="group">
          {#each policies as p (p)}
            <button class:on={permission === p} class:hot={p === "bypass"} onclick={() => { onpermission(p); accessAt = null; }}
              onmouseenter={() => (hovered = p)} onmouseleave={() => (hovered = null)} title={permissionLabels[p]} aria-label={permissionLabels[p]} aria-pressed={permission === p}>
              <Ico name={accessSymbol(p)} size={16} />
            </button>
          {/each}
        </div>
        <span class="access-title">{permissionLabels[hovered ?? permission]}</span>
        <span class="access-help">{permissionHelp(hovered ?? permission, provider)}</span>
      </div>
    {/if}
  {/snippet}
</ModelPickerDropdown>

<style>
  /* The Mac's `ComposerPill`: the agent's logo and the model, quiet until hovered; no chevron, as on the Mac. */
  .agent-pill {
    display: inline-flex; align-items: center; gap: var(--space-6); height: 28px; min-width: 0; max-width: 100%; margin: 0;
    padding: 0 var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2);
    font: var(--text-control); white-space: nowrap;
  }
  .agent-pill .text { overflow: hidden; text-overflow: ellipsis; }
  .agent-pill .detail { color: var(--text3); }
  .agent-pill:hover:not(:disabled), .agent-pill[aria-expanded="true"] { background: var(--smoke); color: var(--paper); }
  .agent-pill:disabled { opacity: 0.6; }
  .anchor { display: none; }
  .agent-pill .effort { color: var(--paper); }
  .agent-pill.hot { color: var(--coral-soft); }
  .agent-pill > :global(svg:last-child:not(:first-child)) { opacity: 0.6; }
  .side-head { display: flex; align-items: baseline; gap: var(--space-4); padding: var(--space-8) var(--space-8) var(--space-4); }
  .side-head > span:first-child { font: var(--text-label); color: var(--text3); white-space: nowrap; }
  .side-model { flex: 1; min-width: 0; text-align: right; font: var(--text-detail); color: var(--text3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .note { display: flex; align-items: center; gap: var(--space-6); margin: 0 0 var(--space-6); padding: var(--space-6) var(--space-6) 0; font: var(--text-detail); color: var(--text3); }
  .option-row { display: flex; align-items: center; flex-wrap: wrap; gap: var(--space-4); }
  .grow { flex: 1; }
  /* A choice of a few as segments on smoke (the Mac's speed choice in `ModelPickerOptions`). */
  .segments { display: inline-flex; gap: var(--space-2); padding: var(--space-2); border-radius: var(--radius-control); background: var(--smoke); }
  .segments button {
    display: inline-flex; align-items: center; gap: var(--space-6); height: 24px; margin: 0; padding: 0 var(--space-8); border: 0;
    border-radius: var(--radius-chip); background: transparent; color: var(--text2); font: var(--text-control); white-space: nowrap;
  }
  .segments button:hover { color: var(--paper); background: transparent; }
  .segments button.on { background: color-mix(in srgb, var(--paper) 8%, transparent); color: var(--paper); }
  .segments button.hot { color: var(--coral-soft); }
  .segments.wide { display: flex; }
  .segments.wide button { flex: 1; justify-content: center; height: 30px; }
  .access-pop {
    position: fixed; z-index: 60; width: 300px; display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8);
    background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-card); box-shadow: var(--shadow-popover);
  }
  .access-head { font: var(--text-label); color: var(--text3); }
  .access-title { font: var(--text-body); color: var(--paper); }
  .access-help { font: var(--text-detail); color: var(--text3); }
</style>
