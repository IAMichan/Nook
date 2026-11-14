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
  import { tr } from "../../lib/i18n.svelte";

  type Tab = "link" | "accounts" | "usage" | "workspace";
  const tabs: { id: Tab; title: string; component?: Component }[] = $derived([
    { id: "link", title: tr("Koppelen", "Link") },
    { id: "accounts", title: tr("Accounts", "Accounts") },
    { id: "usage", title: tr("Gebruik", "Usage"), component: AgentsUsage },
    { id: "workspace", title: tr("Werkruimte", "Workspace"), component: AgentsWorkspace },
  ]);
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
      status =
        (change.install ? tr("{title}: gekoppeld.", "{title}: linked.", { title: change.title }) : tr("{title}: ontkoppeld.", "{title}: unlinked.", { title: change.title })) +
        (backup ? " " + tr("Backup: {path}.", "Backup: {path}.", { path: backup }) : "") +
        (change.install && change.title !== "Claude-abonnement in de balk" ? " " + tr("Start de agent opnieuw zodat het werkt.", "Restart the agent so it takes effect.") : "");
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
      case "installed": return tr("klaar · {path}", "ready · {path}", { path: i.path });
      case "outdated": return tr("Gekoppeld met een oudere versie: werk bij voor toestemming en vragen in de balk", "Linked with an older version: update for permissions and questions in the bar");
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
    if (!confirm(tr("{title} uit Nook halen? De map {folder} en de inlog blijven op je computer staan.", "Remove {title} from Nook? The folder {folder} and the login stay on your computer.", { title: p.title, folder: p.displayHome }))) return;
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
    if (!a) return tr("niet ingelogd", "not signed in");
    return [a.name, a.organization, a.plan].filter(Boolean).join(" · ");
  }
</script>

<h2>{tr("Agents", "Agents")}</h2>
{#if !local}
  <p class="muted">
    {tr(
      "Coding-agents draaien op je computer, niet op je telefoon. Open Nook op je Windows- of Linux-computer om Claude Code, Codex en de andere agents te koppelen; op de telefoon zie je ze via de companion.",
      "Coding agents run on your computer, not on your phone. Open Nook on your Windows or Linux computer to link Claude Code, Codex and the other agents; on your phone you see them through the companion.",
    )}
  </p>
{:else}
  <div class="tabs">
    {#each tabs as t (t.id)}<button class:on={tab === t.id} onclick={() => (tab = t.id)}>{t.title}</button>{/each}
  </div>

  {#if status}<p class="ok note">{status}</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}

  {#if tab === "link"}
    <h3>{tr("Koppel je agents", "Link your agents")}</h3>
    <div class="group">
      {#each integrations.filter((i) => !i.profileId) as i (i.target)}
        <div class="row">
          <div class="info">
            <div class="name"><span class="dot {i.state.kind === 'installed' ? 'unread' : i.state.kind === 'outdated' ? 'waiting' : i.state.kind === 'unreadable' ? 'error' : ''}"></span>{i.title}</div>
            <div class="faint small">{stateText(i)}</div>
          </div>
          <div class="inline">
            {#if i.state.kind === "notInstalled"}
              <button onclick={() => prepare(i, true)}>{tr("Koppel…", "Link…")}</button>
            {:else if i.state.kind === "outdated"}
              <button class="primary" onclick={() => prepare(i, true)}>{tr("Werk bij…", "Update…")}</button>
              <button onclick={() => prepare(i, false)}>{tr("Ontkoppel…", "Unlink…")}</button>
            {:else if i.state.kind === "installed"}
              <button onclick={() => prepare(i, false)}>{tr("Ontkoppel…", "Unlink…")}</button>
            {/if}
          </div>
        </div>
      {/each}
    </div>
    <p class="faint note">
      {tr(
        "Nook laat eerst precies zien wat er verandert en maakt een backup voordat er iets wordt geschreven. Draait Nook niet, dan doen de koppelingen niets. Toestemming geven vanuit de balk kan bij Claude Code en Codex; bij de andere agents beslist Nook nooit iets.",
        "Nook first shows exactly what changes and makes a backup before anything is written. If Nook isn't running, the links do nothing. Granting permission from the bar works for Claude Code and Codex; for the other agents Nook never decides anything.",
      )}
    </p>
    {#if integrations.some((i) => i.profileId)}
      <h3>{tr("Extra accounts", "Extra accounts")}</h3>
      <div class="group">
        {#each integrations.filter((i) => i.profileId) as i (i.target + i.profileId)}
          <div class="row">
            <div class="info">
              <div class="name">{i.title}</div>
              <div class="faint small">{stateText(i)}</div>
            </div>
            {#if i.state.kind === "installed"}
              <button onclick={() => prepare(i, false)}>{tr("Ontkoppel…", "Unlink…")}</button>
            {:else if i.state.kind !== "unreadable"}
              <button onclick={() => prepare(i, true)}>{i.state.kind === "outdated" ? tr("Werk bij…", "Update…") : tr("Koppel…", "Link…")}</button>
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
                {p.label || (p.home ? p.title : tr("Hoofdaccount", "Main account"))}
                {#if p.preferred}<span class="badge">{tr("standaard", "default")}</span>{/if}
              </div>
              <div class="faint small">{account(p)} · {p.displayHome}</div>
              {#if kind === "claude" && p.auth === "apiKey"}
                <div class="inline key">
                  <input type="password" placeholder={p.hasKey ? tr("Sleutel staat in de kluis", "Key is in the keychain") : "sk-ant-…"} bind:value={keyInput[p.id]} />
                  <button onclick={() => saveKey(p)}>{keyInput[p.id] ? tr("Bewaar", "Save") : p.hasKey ? tr("Wis", "Clear") : tr("Bewaar", "Save")}</button>
                </div>
              {/if}
            </div>
            <div class="inline">
              {#if !p.preferred}<button class="ghost" onclick={() => agentApi.preferProfile(p.id).then(load)}>{tr("Maak standaard", "Make default")}</button>{/if}
              {#if kind === "claude"}
                <select value={p.auth ?? "cli"} onchange={(e) => agentApi.setProfileAuth(p.id, e.currentTarget.value as "cli" | "apiKey").then(load)}>
                  <option value="cli">{tr("Abonnement (inloggen)", "Subscription (sign in)")}</option>
                  <option value="apiKey">{tr("API-sleutel", "API key")}</option>
                </select>
              {/if}
              <button class="ghost" title={tr("Inloggen in een terminal", "Sign in in a terminal")} onclick={() => agentApi.runInTerminal(p.loginCommand)}>{tr("Log in…", "Sign in…")}</button>
              {#if p.home}<button class="ghost danger" onclick={() => removeProfile(p)}>{tr("Haal weg", "Remove")}</button>{/if}
            </div>
          </div>
        {/each}
        <div class="row">
          <input placeholder={tr("Naam van een extra account, bijvoorbeeld Werk", "Name of an extra account, for example Work")} bind:value={newLabel[kind]} />
          <button onclick={() => addProfile(kind)}>{tr("Voeg account toe", "Add account")}</button>
        </div>
      </div>
    {/each}
    <p class="faint note">
      {tr(
        "Elk account heeft een eigen map (bijvoorbeeld ~/.claude-werk) met een eigen inlog, zodat privé en werk naast elkaar kunnen. Een API-sleutel staat alleen in de kluis van je systeem, nooit in een bestand.",
        "Each account has its own folder (for example ~/.claude-work) with its own login, so personal and work can live side by side. An API key is only kept in your system's keychain, never in a file.",
      )}
    </p>
  {:else if Current}
    <Current />
  {/if}
{/if}

{#if pending}
  <div class="modal" role="dialog" aria-modal="true">
    <div class="sheet">
      <h3>{pending.install ? tr("Koppel {title}", "Link {title}", { title: pending.title }) : tr("Ontkoppel {title}", "Unlink {title}", { title: pending.title })}</h3>
      {#if pending.unchanged}
        <p class="muted">{tr("Er verandert niets.", "Nothing changes.")}</p>
      {:else}
        <p class="muted small">{tr("Dit verandert in {path}. Je eigen instellingen blijven staan; er komt eerst een backup naast het bestand.", "This changes in {path}. Your own settings stay; a backup is made next to the file first.", { path: pending.path })}</p>
        <DiffView lines={pending.preview} max={360} />
      {/if}
      <div class="inline end">
        <button class="ghost" onclick={cancel}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={pending.unchanged} onclick={write}>{pending.install ? tr("Koppel", "Link") : tr("Ontkoppel", "Unlink")}</button>
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
