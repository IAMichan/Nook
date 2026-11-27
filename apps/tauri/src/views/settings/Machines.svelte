<script lang="ts">
  // Settings › Devices › Machines (`RemoteMachinesSection` on the Mac): the computers your agents can work on over
  // SSH. Each machine is an ssh alias or user@host, with an optional port and key file; the test logs in once and
  // lists the agents found there. A session picks one under the composer ("Runs on").
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { tr } from "../../lib/i18n.svelte";
  import { machinesApi, balanceLevels, isValidHost, suggestedName, type BalanceLevel, type RemoteMachine } from "../../lib/workspace/machines";
  import { agentNames } from "../../lib/agents";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { tip } from "../../components/ui/tip";
  import SettingNote from "./SettingNote.svelte";

  let machines = $state<RemoteMachine[]>([]);
  /** The machine being edited, or "new" for the form to add one; null with the form closed. */
  let editing = $state<string | "new" | null>(null);
  let host = $state("");
  let name = $state("");
  let port = $state("");
  let keyFile = $state("");
  let saving = $state(false);
  let error = $state<string | null>(null);
  /** Per machine: testing, what was found, or what went wrong. */
  let checks = $state<Record<string, { busy: boolean; agents?: string[]; error?: string }>>({});

  let localBalance = $state<BalanceLevel>("normal");

  /** The levels of "Automatic", as the Mac names them. */
  function levelName(l: BalanceLevel): string {
    switch (l) {
      case "prefer": return tr("Voorkeur", "Prefer");
      case "normal": return tr("Normaal", "Normal");
      case "lessOften": return tr("Minder vaak", "Less often");
      case "manualOnly": return tr("Alleen handmatig", "Manual only");
    }
  }

  /** The last part of a project path on this computer, for the list of shared projects. */
  const projectLabel = (p: string) => p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || p;

  async function load() {
    localBalance = await machinesApi.localBalance().catch(() => "normal" as BalanceLevel);
    machines = await machinesApi.list().catch(() => []);
  }

  $effect(() => {
    load();
    const un = machinesApi.onChanged(load);
    return () => { un.then((f) => f()); };
  });

  function openForm(machine: RemoteMachine | null) {
    editing = machine?.id ?? "new";
    host = machine?.host ?? "";
    name = machine?.name ?? "";
    port = machine?.port ? String(machine.port) : "";
    keyFile = machine?.identityFile ?? "";
    error = null;
  }

  const portValue = $derived(port.trim() ? Number(port.trim()) : null);
  const portOk = $derived(portValue === null || (Number.isInteger(portValue) && portValue > 0 && portValue < 65536));
  const canSave = $derived(isValidHost(host) && portOk && !saving);

  async function save() {
    if (!canSave) return;
    saving = true;
    error = null;
    try {
      const saved = await machinesApi.save({ id: editing === "new" ? null : editing, name, host, port: portValue, identityFile: keyFile.trim() || null });
      editing = null;
      await load();
      // A new machine is tested at once, so you see whether ssh gets in and which agents are there.
      test(saved.id);
    } catch (e) {
      error = String(e);
    } finally {
      saving = false;
    }
  }

  async function test(id: string) {
    checks = { ...checks, [id]: { busy: true } };
    try {
      const result = await machinesApi.test(id);
      checks = { ...checks, [id]: { busy: false, agents: result.agents } };
    } catch (e) {
      checks = { ...checks, [id]: { busy: false, error: String(e) } };
    }
  }

  async function remove(id: string) {
    await machinesApi.remove(id).catch(() => {});
    const { [id]: _, ...rest } = checks;
    checks = rest;
    await load();
  }

  async function chooseKey() {
    try {
      const picked = await openDialog({ multiple: false, title: tr("Kies een sleutelbestand", "Choose a key file") });
      if (typeof picked === "string") keyFile = picked;
    } catch (e) {
      error = String(e);
    }
  }

  function address(m: RemoteMachine): string {
    return m.port ? `${m.host}:${m.port}` : m.host;
  }

  function lastUsed(m: RemoteMachine): string {
    if (!m.lastUsedAt) return tr("Nog niet verbonden", "Not connected yet");
    return tr("Laatst bereikt {when}", "Last reached {when}", { when: new Date(m.lastUsedAt).toLocaleString() });
  }
</script>

<div class="section-head">
  <h3>{tr("Machines", "Machines")}</h3>
  {#if editing === null}
    <button class="head-action" onclick={() => openForm(null)}><Ico name="plus" size={14} />{tr("Machine toevoegen", "Add a machine")}</button>
  {/if}
</div>
<p class="section-info">
  {tr(
    "Een agent kan op een andere computer werken: Nook start hem daar via SSH, in een map op die machine, met de login van de agent daar. Kies de machine onder het invoerveld van een nieuwe sessie.",
    "An agent can work on another computer: Nook starts it there over SSH, in a folder on that machine, with the agent's own login there. Pick the machine under the box of a new session.",
  )}
</p>

<div class="group">
  {#each machines as m (m.id)}
    {@const check = checks[m.id]}
    <div class="row machine">
      <span class="mark" aria-hidden="true"><Ico name="server" size={16} /></span>
      <span class="meta">
        <span class="name">{m.name}</span>
        <span class="detail">{address(m)}{m.identityFile ? ` · ${m.identityFile}` : ""}</span>
        {#if check?.busy}
          <span class="detail">{tr("Verbinden…", "Connecting…")}</span>
        {:else if check?.error}
          <span class="detail err">{check.error}</span>
        {:else if check?.agents}
          <span class="detail ok">
            {check.agents.length
              ? tr("Verbonden. Agents daar: {agents}", "Connected. Agents there: {agents}", { agents: check.agents.map((a) => (agentNames as Record<string, string>)[a] ?? a).join(", ") })
              : tr("Verbonden, maar er staat daar nog geen agent op het PATH.", "Connected, but no agent is on the PATH there yet.")}
          </span>
        {:else}
          <span class="detail">{lastUsed(m)}</span>
        {/if}
        {#each Object.entries(m.projectFolders ?? {}) as [project, folder] (project)}
          <!-- A project on this computer shared with the machine: "Automatic" may start it there. -->
          <span class="detail shared">
            <span title={project}>{projectLabel(project)} → {folder}</span>
            <button class="unshare" title={tr("Niet meer delen", "Stop sharing")} aria-label={tr("Niet meer delen", "Stop sharing")} onclick={() => machinesApi.forgetProject(m.id, project).then(load)}>✕</button>
          </span>
        {/each}
      </span>
      <label class="level" title={tr("Automatisch kiezen", "Picked automatically")}>
        <select value={m.balance ?? "normal"} aria-label={tr("Automatisch kiezen", "Picked automatically")}
          onchange={(e) => machinesApi.setBalance(m.id, (e.currentTarget as HTMLSelectElement).value as BalanceLevel).then(load)}>
          {#each balanceLevels as l (l)}<option value={l}>{levelName(l)}</option>{/each}
        </select>
      </label>
      <span class="actions">
        <button class="ghost" disabled={check?.busy} onclick={() => test(m.id)}>{tr("Test verbinding", "Test connection")}</button>
        <button class="ghost" onclick={() => openForm(m)}>{tr("Wijzig", "Edit")}</button>
        <span use:tip={tr("Machine verwijderen", "Remove machine")}>
          <ConfirmedButton
            class="icon-danger"
            confirmTitle={tr("Machine verwijderen", "Remove machine")}
            question={tr("“{name}” verwijderen?", "Remove “{name}”?", { name: m.name })}
            detail={tr(
              "Sessies die er al draaien blijven zoals ze zijn. Je sleutels en je ssh-config blijven staan.",
              "Sessions already running there stay as they are. Your keys and your ssh config stay as they are.",
            )}
            onconfirm={() => remove(m.id)}
          >
            <Ico name="trash-2" size={14} />
          </ConfirmedButton>
        </span>
      </span>
    </div>
  {:else}
    {#if editing === null}
      <p class="empty-note">{tr("Nog geen machine. Voeg er een toe met een ssh-alias of gebruiker@host.", "No machine yet. Add one with an ssh alias or user@host.")}</p>
    {/if}
  {/each}

  {#if editing !== null}
    <form class="row stacked form" onsubmit={(e) => { e.preventDefault(); save(); }}>
      <label>
        <span>{tr("Adres", "Address")}</span>
        <input bind:value={host} placeholder={tr("buildbox of ik@buildbox.local", "buildbox or me@buildbox.local")} spellcheck="false" autocomplete="off" />
      </label>
      <label>
        <span>{tr("Naam", "Name")}</span>
        <input bind:value={name} placeholder={suggestedName(host) || tr("Naam (optioneel)", "Name (optional)")} />
      </label>
      <div class="pair">
        <label class="port">
          <span>{tr("Poort", "Port")}</span>
          <input bind:value={port} inputmode="numeric" placeholder="22" />
        </label>
        <label class="key">
          <span>{tr("Sleutelbestand", "Key file")}</span>
          <span class="key-row">
            <input bind:value={keyFile} placeholder={tr("Je ssh-config en agent", "Your ssh config and agent")} spellcheck="false" />
            <button type="button" class="ghost" onclick={chooseKey}>{tr("Kies…", "Choose…")}</button>
          </span>
        </label>
      </div>
      {#if !portOk}
        <SettingNote tone="error" text={tr("Een poort is een getal van 1 tot 65535.", "A port is a number from 1 to 65535.")} />
      {/if}
      {#if error}
        <SettingNote tone="error" text={error} />
      {/if}
      <SettingNote
        text={tr(
          "Nook logt in met een sleutel (uit je ssh-agent, je ssh-config of het sleutelbestand). Inloggen met een wachtwoord kan hier nog niet. Verbind de eerste keer zelf met ssh in een terminal, zodat ssh de machine kent.",
          "Nook logs in with a key (from your ssh agent, your ssh config or the key file). Logging in with a password is not available here yet. Connect once yourself with ssh in a terminal first, so ssh knows the machine.",
        )}
      />
      <span class="buttons">
        <button type="button" class="ghost" onclick={() => (editing = null)}>{tr("Annuleer", "Cancel")}</button>
        <button type="submit" class="primary" disabled={!canSave}>{editing === "new" ? tr("Machine toevoegen", "Add a machine") : tr("Bewaar", "Save")}</button>
      </span>
    </form>
  {/if}
</div>

<!-- This computer takes part in "Automatic" too, with a level of its own. -->
<h3>{tr("Automatisch verdelen", "Automatic")}</h3>
<p class="section-info">
  {tr(
    "Met Automatisch onder het invoerveld kiest Nook voor een nieuwe sessie deze computer of een machine waar het project ook staat: de plek die bereikbaar is, de agent heeft en het minst te doen heeft voor zijn niveau. Een project staat op een machine zodra je er één keer een sessie van daar startte.",
    "With Automatic under the box, Nook starts a new session on this computer or on a machine the project is shared with: the place that answers, has the agent and has the least to do for its level. A project is shared with a machine once you started a session of it there.",
  )}
</p>
<div class="group">
  <label class="row">
    <span>{tr("Deze computer", "This computer")}</span>
    <select value={localBalance} onchange={(e) => machinesApi.setLocalBalance((e.currentTarget as HTMLSelectElement).value as BalanceLevel).then(load)}>
      {#each balanceLevels as l (l)}<option value={l}>{levelName(l)}</option>{/each}
    </select>
  </label>
</div>

<style>
  .level { flex: none; }
  .shared { display: inline-flex; align-items: center; gap: var(--space-4); }
  .unshare { padding: 0 var(--space-4); border: 0; background: none; color: var(--text3); font: var(--text-detail); }
  .unshare:hover { background: none; color: var(--paper); }
  .machine { flex-wrap: nowrap; }
  .machine .mark { display: grid; place-items: center; width: 22px; flex: none; color: var(--text2); }
  .machine .meta { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .machine .name { font: var(--text-emphasis); color: var(--paper); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .machine .detail { font: var(--text-detail); color: var(--text2); overflow: hidden; text-overflow: ellipsis; }
  .machine .detail.err { color: var(--coral); }
  .machine .detail.ok { color: var(--mint); }
  .actions { display: inline-flex; align-items: center; gap: var(--space-4); flex: none; }
  .actions :global(.icon-danger) { display: grid; place-items: center; width: 26px; height: 26px; padding: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .actions :global(.icon-danger:hover) { background: var(--smoke); color: var(--coral); }
  .form label { display: flex; flex-direction: column; gap: var(--space-4); font: var(--text-detail); color: var(--text2); }
  .form input { font: var(--text-body); }
  .pair { display: flex; gap: var(--space-12); }
  .pair .port { flex: 0 0 96px; }
  .pair .key { flex: 1; min-width: 0; }
  .key-row { display: flex; gap: var(--space-6); }
  .key-row input { flex: 1; min-width: 0; }
  .buttons { display: flex; justify-content: flex-end; gap: var(--space-6); }
</style>
