<script lang="ts">
  // The agent pill of a session composer and the picker behind it (the Mac's `ComposerPill` with `AgentModelPicker` in
  // `ModelPickerDropdown`): the pill shows the agent's logo and its model; the panel has a rail of agents (one place per
  // account when an agent has several) with a "+" at its foot for Settings › Coding agents, the shown agent's column
  // (its name, a line about it, a search field and the models) and, as `ModelPickerOptions`, a footer with the mode, the
  // reasoning effort and the access. The new-session composer and a running session's composer both use this one view.
  import { api } from "../../../lib/api";
  import type { AgentProfile } from "../../../lib/agents";
  import { tr } from "../../../lib/i18n.svelte";
  import {
    effortLabels, effortLevels, permissionHelp, permissionLabels, type ExecutionMode, type PermissionPolicy, type ProviderInfo, type RunProvider,
  } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { catalog, compactModelName } from "../../../lib/workspace/models.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
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

  interface Place { id: string; provider: ProviderInfo; profile: AgentProfile | null }

  let open = $state(false);
  let hovered = $state<PermissionPolicy | null>(null);
  let shownId = $state("");
  let query = $state("");
  let highlight = $state(0);

  const own = (p: RunProvider) => profiles.filter((x) => x.kind === p);
  const places = $derived<Place[]>(providers.flatMap((p) => {
    const accounts = own(p.provider);
    return accounts.length > 1 ? accounts.map((a) => ({ id: `${p.provider}/${a.id}`, provider: p, profile: a })) : [{ id: p.provider, provider: p, profile: accounts[0] ?? null }];
  }));
  const chosenId = $derived(own(provider).length > 1 ? `${provider}/${profileId}` : provider);
  const shown = $derived(places.find((p) => p.id === shownId) ?? places.find((p) => p.id === chosenId) ?? places[0]);
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

  interface Row { id: string; title: string; trailing?: string; model: string }
  const rows = $derived.by((): Row[] => {
    if (!shown) return [];
    const p = shown.provider.provider;
    const q = query.trim();
    // The manifest's current models first (`ModelManifest`), then the ones used here before that it does not list.
    const listed = catalog.byAgent[p] ?? [];
    const known = knownModels(p).filter((m) => !catalog.find(p, m));
    const chosenLegacy = listed.filter((m) => !m.current && p === provider && catalog.find(p, model)?.id === m.id);
    const all: Row[] = [
      { id: "", title: tr("Standaard", "Default"), trailing: tr("van de agent", "the agent's own"), model: "" },
      ...[...listed.filter((m) => m.current), ...chosenLegacy].map((m) => ({ id: m.id, title: m.name, trailing: m.isNew ? tr("Nieuw", "New") : undefined, model: m.id })),
      ...known.map((m) => ({ id: m, title: m, model: m })),
    ].filter((r) => !q || `${r.title} ${r.model}`.toLowerCase().includes(q.toLowerCase()));
    // Any model name the agent accepts: typed in the search, it becomes a row of its own.
    if (q && !all.some((r) => r.model === q) && !catalog.find(p, q)) all.push({ id: `use:${q}`, title: tr("Gebruik “{model}”", "Use “{model}”", { model: q }), model: q });
    return all;
  });

  const isChosen = (r: Row) =>
    !!shown && shown.id === chosenId && !r.id.startsWith("use:") && (r.model === model || (!!r.model && catalog.find(provider, model)?.id === r.model));

  function opened() {
    shownId = chosenId;
    query = "";
    highlight = 0;
  }

  function pick(r: Row) {
    if (!shown) return;
    open = false;
    const p = shown.provider.provider;
    const account = shown.profile?.id ?? (p === provider ? profileId : (own(p).find((a) => a.preferred) ?? own(p)[0])?.id ?? p);
    onchoose(p, account, r.model);
  }

  function openSettings() {
    open = false;
    try { localStorage.setItem("settings.section", "agents"); } catch { /* opens on the last page instead */ }
    api.showMain("settings");
  }

  // ↑/↓ move over the models while the search keeps the keyboard; Return picks the highlighted one.
  function keys(e: KeyboardEvent) {
    if (e.key === "ArrowDown") { e.preventDefault(); highlight = Math.min(highlight + 1, rows.length - 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); highlight = Math.max(highlight - 1, 0); }
    else if (e.key === "Enter" && rows[highlight]) { e.preventDefault(); pick(rows[highlight]); }
  }

  function focusOnMount(node: HTMLInputElement) {
    node.focus();
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
      if (!open) { opened(); open = true; }
      if ((e as CustomEvent<string>).detail === "access") {
        requestAnimationFrame(() => anchor?.parentElement?.querySelector<HTMLButtonElement>(".access-pill")?.click());
      }
    };
    window.addEventListener("nook-agents-picker", on);
    return () => window.removeEventListener("nook-agents-picker", on);
  });
</script>

<span class="anchor" bind:this={anchor}></span>
<Dropdown bind:open width={levels.length ? 510 : 340} onopen={opened} label={tr("Agent en model kiezen", "Choose the agent and model")}>
  {#snippet trigger({ toggle, open })}
    <button class="agent-pill" onclick={toggle} {disabled} aria-expanded={open} title={title ?? agentName}
      aria-label={tr("Agent en model", "Agent and model")}>
      <AgentMark agent={agentName} size={15} />
      <span class="text">{pillText}{#if account?.label}<span class="detail"> · {account.label}</span>{/if}</span>{#if effortWord}<span class="effort">{effortWord}</span>{/if}
    </button>
  {/snippet}
  {#snippet children()}
    <!-- `ModelPicker`: the rail of agents, the shown agent's column, the effort column beside it (`ModelPickerReasoning`)
         and the session's options under them (`ModelPickerOptions`). -->
    <div class="picker">
      <div class="rail">
        {#each places as p (p.id)}
          <button class="place" class:on={p.id === shown?.id} class:missing={!p.provider.executable} onclick={() => { shownId = p.id; query = ""; highlight = 0; }}
            title={p.profile?.label ? `${p.provider.name} · ${p.profile.label}` : p.provider.name} aria-label={p.provider.name} aria-pressed={p.id === shown?.id}>
            <AgentMark agent={p.provider.name} size={18} />
            {#if p.id === chosenId && p.id !== shown?.id}<span class="dot" aria-hidden="true"></span>{/if}
          </button>
        {/each}
        <span class="rail-space"></span>
        <button class="place add" onclick={openSettings} title={tr("Een agent toevoegen in Instellingen › Coding-agents", "Add an agent in Settings › Coding agents")} aria-label={tr("Toevoegen", "Add")}><Ico name="plus" size={14} /></button>
      </div>
      <div class="column">
        {#if shown}
          <div class="dd-header">{shown.provider.name}</div>
          <p class="place-detail">
            {#if !shown.provider.executable}{tr("{agent} staat niet op deze computer.", "{agent} isn't installed on this computer.", { agent: shown.provider.name })}
            {:else if shown.profile?.label}{shown.profile.label}
            {:else}{tr("Met je eigen aanmelding bij {agent}.", "With your own sign-in to {agent}.", { agent: shown.provider.name })}{/if}
          </p>
          <label class="search">
            <Ico name="search" size={14} />
            <input use:focusOnMount bind:value={query} oninput={() => (highlight = 0)} onkeydown={keys} placeholder={tr("Zoek modellen…", "Search models…")} aria-label={tr("Zoek modellen", "Search models")} />
          </label>
          <div class="list">
            {#each rows as r, i (r.id)}
              <DropdownRow brand={shown.provider.name} title={r.title} trailing={r.trailing} chosen={isChosen(r)} highlighted={i === highlight && query.length > 0}
                onclick={() => pick(r)} />
            {/each}
          </div>
        {/if}
      </div>
      {#if levels.length}
        <div class="side">
          <div class="side-head"><span>{tr("Denkniveau", "Thinking effort")}</span><span class="side-model">{model || agentName}</span></div>
          <DropdownRow symbol="circle-dashed" title={effortLabels[""]} trailing={!effort ? "✓" : undefined} chosen={!effort} onclick={() => oneffort(null)} />
          {#each levels as l (l)}
            <DropdownRow symbol="gauge" title={effortLabels[l] ?? l} trailing={effort === l ? "✓" : undefined} chosen={effort === l} onclick={() => oneffort(l)} />
          {/each}
        </div>
      {/if}
    </div>
    <div class="options">
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
</Dropdown>

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
  /* The panel's own padding goes: the rail runs to its edges, as `ModelPicker` draws it. */
  .picker { display: flex; align-items: stretch; margin: calc(-1 * var(--space-4)) calc(-1 * var(--space-4)) 0; min-height: 0; }
  .rail {
    display: flex; flex-direction: column; align-items: center; gap: var(--space-4); width: 44px; flex: none;
    padding: var(--space-6); background: color-mix(in srgb, var(--paper) 3%, transparent); border-right: 1px solid var(--line2);
  }
  .rail-space { flex: 1; }
  .place {
    position: relative; display: grid; place-items: center; width: 32px; height: 32px; flex: none; padding: 0; margin: 0;
    border: 0; border-radius: var(--radius-control); background: transparent; color: var(--paper);
  }
  .place:hover { background: var(--smoke); }
  .place.on { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .place.missing { opacity: 0.5; }
  .place.add { color: var(--text3); }
  .dot { position: absolute; top: var(--space-4); right: var(--space-4); width: 4px; height: 4px; border-radius: 50%; background: color-mix(in srgb, var(--paper) 70%, transparent); }
  .column { display: flex; flex-direction: column; flex: 1; min-width: 0; padding: 0 var(--space-4) var(--space-4); }
  .place-detail { margin: 0; padding: 0 var(--space-8) var(--space-4); font: var(--text-detail); color: var(--text3); }
  .search { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-8); border-bottom: 1px solid var(--line2); color: var(--text3); }
  .search input { flex: 1; min-width: 0; padding: 0; margin: 0; border: 0; outline: 0; background: transparent; font: var(--text-body); color: var(--paper); box-shadow: none; }
  .search input::placeholder { color: var(--text3); }
  .list { max-height: 240px; overflow-y: auto; padding: var(--space-4) 0; }
  /* The effort column (`ModelPickerReasoning`), 170 pt beside the models behind a hairline. */
  .side { width: 170px; flex: none; display: flex; flex-direction: column; padding: 0 var(--space-4); border-left: 1px solid var(--line2); }
  .side-head { display: flex; align-items: baseline; gap: var(--space-4); padding: var(--space-8) var(--space-8) var(--space-4); }
  .side-head > span:first-child { font: var(--text-label); color: var(--text3); white-space: nowrap; }
  .side-model { flex: 1; min-width: 0; text-align: right; font: var(--text-detail); color: var(--text3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .options { margin: 0 calc(-1 * var(--space-4)) calc(-1 * var(--space-4)); padding: var(--space-6); border-top: 1px solid var(--line2); }
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
