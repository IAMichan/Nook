<script lang="ts">
  // Instellingen › Agents: koppelen (met precies wat er verandert, een backup en pas na OK), accounts, gebruik en
  // de werkruimte voor agents.
  import type { Component } from "svelte";
  import { agentApi, agentNames, type AgentKind, type AgentProfile, type Integration, type LinkPreview } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { nook } from "../../lib/state.svelte";
  import DiffView from "../agents/DiffView.svelte";
  import AgentsUsage from "./AgentsUsage.svelte";
  import AgentsWorkspace from "./AgentsWorkspace.svelte";

  type Tab = "link" | "accounts" | "usage" | "workspace";
  const tabs: { id: Tab; title: string; component?: Component }[] = [
    { id: "link", title: "Koppelen" },
    { id: "accounts", title: "Accounts" },
    { id: "usage", title: "Gebruik", component: AgentsUsage },
    { id: "workspace", title: "Werkruimte", component: AgentsWorkspace },
  ];
  let tab = $state<Tab>((localStorage.getItem("settings.agents.tab") as Tab) || "link");
  $effect(() => {
    localStorage.setItem("settings.agents.tab", tab);
  });
  const Current = $derived(tabs.find((t) => t.id === tab)?.component);

  let integrations = $state<Integration[]>([]);
  let profiles = $state<AgentProfile[]>([]);
  let pending = $state<LinkPreview | null>(null);
  let status = $state<string | null>(null);
  let error = $state<string | null>(null);
  let newLabel = $state<Record<string, string>>({});
  let keyInput = $state<Record<string, string>>({});

  const local = $derived(nook.info?.capabilities.localAgents ?? false);

  async function load() {
    if (!local) return;
    [integrations, profiles] = await Promise.all([agentApi.integrations(), agentApi.profiles()]);
    agents.loadHistory();
  }
  $effect(() => {
    load();
  });

  async function prepare(i: Integration, install: boolean) {
    error = status = null;
    try {
      pending = await agentApi.prepareLink(i.target, install, i.profileId);
    } catch (e) {
      error = String(e);
    }
  }

  async function write() {
    if (!pending) return;
    const change = pending;
    pending = null;
    try {
      const backup = await agentApi.applyLink(change.id);
      const verb = change.install ? "gekoppeld" : "ontkoppeld";
      status =
        `${change.title}: ${verb}.` +
        (backup ? ` Backup: ${backup}.` : "") +
        (change.install && change.title !== "Claude-abonnement in de balk" ? " Start de agent opnieuw zodat het werkt." : "");
    } catch (e) {
      error = String(e);
    }
    load();
  }

  function cancel() {
    if (pending) agentApi.discardLink(pending.id);
    pending = null;
  }

  function stateText(i: Integration): string {
    switch (i.state.kind) {
      case "installed": return `klaar · ${i.path}`;
      case "outdated": return "Gekoppeld met een oudere versie: werk bij voor toestemming en vragen in de balk";
      case "unreadable": return i.state.detail;
      default: return i.detail;
    }
  }

  const groups = $derived(
    (Object.keys(agentNames) as AgentKind[]).filter((k) => k === "claude" || k === "codex"),
  );

  async function addProfile(kind: AgentKind) {
    try {
      await agentApi.addProfile(kind, newLabel[kind] ?? "");
      newLabel[kind] = "";
    } catch (e) {
      error = String(e);
    }
    load();
  }

  async function removeProfile(p: AgentProfile) {
    if (!confirm(`${p.title} uit Nook halen? De map ${p.displayHome} en de inlog blijven op je computer staan.`)) return;
    try {
      await agentApi.removeProfile(p.id);
    } catch (e) {
      error = String(e);
    }
    load();
  }

  async function saveKey(p: AgentProfile) {
    await agentApi.setProfileKey(p.id, keyInput[p.id] ?? "");
    keyInput[p.id] = "";
    load();
  }

  function account(p: AgentProfile): string {
    const a = agents.history?.accounts[p.id];
    if (!a) return "niet ingelogd";
    return [a.name, a.organization, a.plan].filter(Boolean).join(" · ");
  }
</script>

<h2>Agents</h2>
{#if !local}
  <p class="muted">
    Coding-agents draaien op je computer, niet op je telefoon. Open Nook op je Windows- of Linux-computer om Claude Code,
    Codex en de andere agents te koppelen; op de telefoon zie je ze via de companion.
  </p>
{:else}
  <div class="tabs">
    {#each tabs as t (t.id)}<button class:on={tab === t.id} onclick={() => (tab = t.id)}>{t.title}</button>{/each}
  </div>

  {#if status}<p class="ok note">{status}</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}

  {#if tab === "link"}
    <h3>Koppel je agents</h3>
    <div class="group">
      {#each integrations.filter((i) => !i.profileId) as i (i.target)}
        <div class="row">
          <div class="info">
            <div class="name"><span class="dot {i.state.kind === 'installed' ? 'unread' : i.state.kind === 'outdated' ? 'waiting' : i.state.kind === 'unreadable' ? 'error' : ''}"></span>{i.title}</div>
            <div class="faint small">{stateText(i)}</div>
          </div>
          <div class="inline">
            {#if i.state.kind === "notInstalled"}
              <button onclick={() => prepare(i, true)}>Koppel…</button>
            {:else if i.state.kind === "outdated"}
              <button class="primary" onclick={() => prepare(i, true)}>Werk bij…</button>
              <button onclick={() => prepare(i, false)}>Ontkoppel…</button>
            {:else if i.state.kind === "installed"}
              <button onclick={() => prepare(i, false)}>Ontkoppel…</button>
            {/if}
          </div>
        </div>
      {/each}
    </div>
    <p class="faint note">
      Nook laat eerst precies zien wat er verandert en maakt een backup voordat er iets wordt geschreven. Draait Nook niet,
      dan doen de koppelingen niets. Toestemming geven vanuit de balk kan bij Claude Code en Codex; bij de andere agents
      beslist Nook nooit iets.
    </p>
    {#if integrations.some((i) => i.profileId)}
      <h3>Extra accounts</h3>
      <div class="group">
        {#each integrations.filter((i) => i.profileId) as i (i.target + i.profileId)}
          <div class="row">
            <div class="info">
              <div class="name">{i.title}</div>
              <div class="faint small">{stateText(i)}</div>
            </div>
            {#if i.state.kind === "installed"}
              <button onclick={() => prepare(i, false)}>Ontkoppel…</button>
            {:else if i.state.kind !== "unreadable"}
              <button onclick={() => prepare(i, true)}>{i.state.kind === "outdated" ? "Werk bij…" : "Koppel…"}</button>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  {:else if tab === "accounts"}
    {#each groups as kind (kind)}
      <h3>{agentNames[kind]}</h3>
      <div class="group">
        {#each profiles.filter((p) => p.kind === kind) as p (p.id)}
          <div class="row">
            <div class="info">
              <div class="name">
                {p.label || (p.home ? p.title : "Hoofdaccount")}
                {#if p.preferred}<span class="badge">standaard</span>{/if}
              </div>
              <div class="faint small">{account(p)} · {p.displayHome}</div>
              {#if kind === "claude" && p.auth === "apiKey"}
                <div class="inline key">
                  <input type="password" placeholder={p.hasKey ? "Sleutel staat in de kluis" : "sk-ant-…"} bind:value={keyInput[p.id]} />
                  <button onclick={() => saveKey(p)}>{keyInput[p.id] ? "Bewaar" : p.hasKey ? "Wis" : "Bewaar"}</button>
                </div>
              {/if}
            </div>
            <div class="inline">
              {#if !p.preferred}<button class="ghost" onclick={() => agentApi.preferProfile(p.id).then(load)}>Maak standaard</button>{/if}
              {#if kind === "claude"}
                <select value={p.auth ?? "cli"} onchange={(e) => agentApi.setProfileAuth(p.id, e.currentTarget.value as "cli" | "apiKey").then(load)}>
                  <option value="cli">Abonnement (inloggen)</option>
                  <option value="apiKey">API-sleutel</option>
                </select>
              {/if}
              <button class="ghost" title="Inloggen in een terminal" onclick={() => agentApi.runInTerminal(p.loginCommand)}>Log in…</button>
              {#if p.home}<button class="ghost danger" onclick={() => removeProfile(p)}>Haal weg</button>{/if}
            </div>
          </div>
        {/each}
        <div class="row">
          <input placeholder="Naam van een extra account, bijvoorbeeld Werk" bind:value={newLabel[kind]} />
          <button onclick={() => addProfile(kind)}>Voeg account toe</button>
        </div>
      </div>
    {/each}
    <p class="faint note">
      Elk account heeft een eigen map (bijvoorbeeld ~/.claude-werk) met een eigen inlog, zodat privé en werk naast elkaar
      kunnen. Een API-sleutel staat alleen in de kluis van je systeem, nooit in een bestand.
    </p>
  {:else if Current}
    <Current />
  {/if}
{/if}

{#if pending}
  <div class="modal" role="dialog" aria-modal="true">
    <div class="sheet">
      <h3>{pending.install ? "Koppel" : "Ontkoppel"} {pending.title}</h3>
      {#if pending.unchanged}
        <p class="muted">Er verandert niets.</p>
      {:else}
        <p class="muted small">Dit verandert in {pending.path}. Je eigen instellingen blijven staan; er komt eerst een backup naast het bestand.</p>
        <DiffView lines={pending.preview} max={360} />
      {/if}
      <div class="inline end">
        <button class="ghost" onclick={cancel}>Annuleer</button>
        <button class="primary" disabled={pending.unchanged} onclick={write}>{pending.install ? "Koppel" : "Ontkoppel"}</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .tabs { display: inline-flex; gap: 2px; background: var(--field); border: 1px solid var(--line); border-radius: 10px; padding: 2px; }
  .tabs button { border: none; background: none; color: var(--text2); padding: 4px 14px; }
  .tabs button.on { background: var(--smoke); color: var(--paper); }
  .info { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .name { display: flex; align-items: center; gap: 6px; }
  .small { font-size: 12px; }
  .badge { font-size: 10px; background: var(--smoke); border-radius: 6px; padding: 1px 6px; color: var(--text2); }
  .ok { color: var(--mint); }
  .key input { width: 220px; }
  .row input:not([type="checkbox"]) { flex: 1; }
  .modal { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: flex; align-items: center; justify-content: center; z-index: 20; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 16px 18px; width: min(720px, 92vw); max-height: 86vh; display: flex; flex-direction: column; gap: 10px; }
  .sheet h3 { margin: 0; color: var(--paper); font-size: 15px; }
  .end { justify-content: flex-end; }
</style>
