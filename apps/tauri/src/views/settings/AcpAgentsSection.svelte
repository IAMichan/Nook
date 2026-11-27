<script lang="ts">
  // Settings › Coding agents › ACP agents (`AcpAgentsSection` on the Mac, AG-21): custom agents speaking ACP
  // (Agent Client Protocol), picked from the ACP registry (`agentclientprotocol.com`) or entered manually. Each runs
  // as an account of AgentKind::Acp ("ACP · Kiro"); removing it deletes any binary copy Nook downloaded for it.
  import { ask } from "../../lib/confirm.svelte";
  import { agents as agentStore } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { workspaceApi, type CustomAgent, type RegistryEntry } from "../../lib/workspace/api";
  import { filterAndSortRegistry, formatCommandLine, parseAcpCommand, shortSha256 } from "../../lib/workspace/custom-acp";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import ConnectionRow from "./ConnectionRow.svelte";

  let { onchange }: { onchange?: () => void } = $props();

  let list = $state<CustomAgent[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let justAdded = $state<string | null>(null);
  let addMenuAnchor = $state<DOMRect | null>(null);

  // Registry modal state
  let showRegistry = $state(false);
  let registryEntries = $state<RegistryEntry[]>([]);
  let registryLoading = $state(false);
  let registryError = $state<string | null>(null);
  let registryQuery = $state("");
  let chosenEntry = $state<RegistryEntry | null>(null);
  let installing = $state(false);
  let installError = $state<string | null>(null);

  // Manual modal state
  let showManual = $state(false);
  let manualName = $state("");
  let manualCommand = $state("");
  let manualChecking = $state(false);
  let manualCheckOk = $state<string | null>(null);
  let manualCheckErr = $state<string | null>(null);
  let manualSaving = $state(false);
  let manualError = $state<string | null>(null);

  async function load() {
    loading = true;
    try {
      list = await workspaceApi.customAcpList();
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    load();
  });

  const shownRegistry = $derived(filterAndSortRegistry(registryEntries, registryQuery));
  const parsedManual = $derived(parseAcpCommand(manualCommand));
  const canAddManual = $derived(manualName.trim().length > 0 && parsedManual !== null && !manualSaving);

  const addMenuSections = $derived<MenuItem[][]>([
    [
      { label: tr("Uit het ACP-register…", "From the ACP registry…"), icon: "layout-grid", onselect: openRegistry },
      { label: tr("Zelf invullen…", "Enter manually…"), icon: "terminal", onselect: openManual },
    ],
  ]);

  function openAddMenu(e: MouseEvent) {
    addMenuAnchor = (e.currentTarget as HTMLElement).getBoundingClientRect();
  }

  async function openRegistry() {
    addMenuAnchor = null;
    showRegistry = true;
    registryQuery = "";
    chosenEntry = null;
    installError = null;
    registryError = null;
    registryLoading = true;
    try {
      registryEntries = await workspaceApi.customAcpRegistry();
      if (registryEntries.length === 0) {
        registryError = tr("Het register gaf geen agents terug.", "The registry returned no agents.");
      }
    } catch (e) {
      registryError = tr("Het register laden lukte niet: {error}", "Could not load the registry: {error}", { error: String(e) });
    } finally {
      registryLoading = false;
    }
  }

  function closeRegistry() {
    if (installing) return;
    showRegistry = false;
  }

  function openManual() {
    addMenuAnchor = null;
    showManual = true;
    manualName = "";
    manualCommand = "";
    manualChecking = false;
    manualCheckOk = null;
    manualCheckErr = null;
    manualSaving = false;
    manualError = null;
  }

  function closeManual() {
    if (manualSaving) return;
    showManual = false;
  }

  function registryDetail(entry: RegistryEntry): string {
    const parts = [entry.version];
    if (!entry.command && entry.binary) {
      parts.push(tr("download", "download"));
    } else if (!entry.supported) {
      parts.push(tr("niet voor deze computer", "not for this computer"));
    }
    if (entry.description) parts.push(entry.description);
    return parts.join(" · ");
  }

  const registryCheckDetail = $derived.by(() => {
    if (chosenEntry?.command) {
      return tr("Start: {command}", "Runs: {command}", {
        command: [chosenEntry.command, ...chosenEntry.arguments].join(" "),
      });
    }
    if (chosenEntry?.binary) {
      return tr("Downloadt {url} (SHA-256 {hash})", "Downloads {url} (SHA-256 {hash})", {
        url: chosenEntry.binary.archive,
        hash: shortSha256(chosenEntry.binary.sha256),
      });
    }
    return tr(
      "Kies een agent om te zien welke opdracht Nook draait, of welk bestand het downloadt.",
      "Pick an agent to see the command Nook will run, or the file it will download.",
    );
  });

  async function confirmRegistry() {
    if (!chosenEntry || !chosenEntry.supported || installing) return;
    installing = true;
    installError = null;
    try {
      const added = await workspaceApi.customAcpAddRegistry($state.snapshot(chosenEntry));
      justAdded = added.profileId;
      showRegistry = false;
      await Promise.all([load(), workspace.refresh()]);
      agentStore.loadHistory(true);
      onchange?.();
    } catch (e) {
      installError = String(e);
    } finally {
      installing = false;
    }
  }

  async function checkManualCommand() {
    const parsed = parsedManual;
    if (!parsed || manualChecking) return;
    const cmdText = manualCommand;
    const program = parsed.command;
    manualChecking = true;
    manualCheckOk = null;
    manualCheckErr = null;
    try {
      const found = await workspaceApi.customAcpCheckCommand(cmdText);
      // Ignore stale result if the command changed while checking.
      if (manualCommand !== cmdText) return;
      if (found) {
        manualCheckOk = tr("Gevonden in {path}.", "Found at {path}.", { path: found });
      } else {
        manualCheckErr = tr(
          "Nook kon {program} niet vinden op deze computer. Installeer het eerst, of voeg het toch toe als het alleen in het pad van je sessies staat.",
          "Nook could not find {program} on this computer. Install it first, or add it anyway if it is only on the path of your sessions.",
          { program },
        );
      }
    } catch (e) {
      if (manualCommand === cmdText) manualCheckErr = String(e);
    } finally {
      manualChecking = false;
    }
  }

  async function confirmManual() {
    if (!canAddManual) return;
    manualSaving = true;
    manualError = null;
    try {
      const added = await workspaceApi.customAcpAddManual(manualName.trim(), manualCommand);
      justAdded = added.profileId;
      showManual = false;
      await Promise.all([load(), workspace.refresh()]);
      agentStore.loadHistory(true);
      onchange?.();
    } catch (e) {
      manualError = String(e);
    } finally {
      manualSaving = false;
    }
  }

  async function removeAgent(agent: CustomAgent) {
    if (
      !(await ask({
        question: tr("“{title}” verwijderen?", "Remove “{title}”?", { title: agent.name }),
        detail: tr(
          "Nook vergeet deze agent en het account waarmee zijn sessies liepen, en verwijdert een kopie die het ervoor downloadde.",
          "Nook forgets this agent and the account its sessions ran as, and deletes a copy it downloaded for it.",
        ),
        confirmTitle: tr("Agent verwijderen", "Remove agent"),
      }))
    ) {
      return;
    }
    error = null;
    try {
      await workspaceApi.customAcpRemove(agent.profileId);
      await Promise.all([load(), workspace.refresh()]);
      agentStore.loadHistory(true);
      onchange?.();
    } catch (e) {
      error = String(e);
    }
  }
</script>

<div class="acp-head">
  <h3>{tr("Andere agents (ACP)", "Other agents (ACP)")}</h3>
  <button type="button" class="head-action" onclick={openAddMenu}>
    <Ico name="plus" size={14} />{tr("ACP-agent toevoegen", "Add ACP agent")}
  </button>
</div>
<p class="section-info">
  {tr(
    "Start via je login-shell, dus npx, uvx, nvm en asdf werken zoals in Terminal. Inloggen gebeurt in de eerste sessie.",
    "Starts through your login shell, so npx, uvx, nvm and asdf work as in Terminal. It signs in during its first session.",
  )}
</p>

{#if error}<p class="err">{error}</p>{/if}

<div class="group">
  {#if !loading && list.length === 0}
    <div class="empty-card">
      <div class="empty-title">{tr("Nog geen ACP-agents", "No ACP agents yet")}</div>
      <div class="empty-detail">
        {tr(
          "Elke agent die ACP spreekt kan erbij: kies er een uit het register of vul zijn opdracht in.",
          "Any agent that speaks ACP can be added: pick one from the registry or enter its command.",
        )}
      </div>
    </div>
  {:else}
    {#each list as agent (agent.profileId)}
      {@const commandLine = formatCommandLine(agent)}
      {@const stateLabel = agent.installedAt ? tr("Geïnstalleerd", "Installed") : tr("Toegevoegd", "Added")}
      <ConnectionRow
        title={agent.name}
        version={agent.version ?? null}
        status={`${stateLabel} · ${commandLine}`}
        startsOpen={agent.profileId === justAdded}
        danger={[{ label: tr("Agent verwijderen", "Remove agent"), icon: "trash-2", onselect: () => removeAgent(agent) }]}
      >
        {#snippet icon()}<AgentMark agent={agent.name} size={22} />{/snippet}
        {#snippet expanded()}
          <div class="kv">
            <span>{tr("Opdracht", "Command")}</span>
            <span class="mono">{commandLine}</span>
          </div>
          {#if agent.installedAt}
            <div class="kv">
              <span>{tr("Geïnstalleerd in", "Installed in")}</span>
              <span class="mono">{agent.installedAt}</span>
            </div>
          {/if}
          <p class="text">
            {tr(
              "Start via je login-shell, dus npx, uvx, nvm en asdf werken zoals in Terminal. Inloggen gebeurt in de eerste sessie.",
              "Starts through your login shell, so npx, uvx, nvm and asdf work as in Terminal. It signs in during its first session.",
            )}
          </p>
        {/snippet}
      </ConnectionRow>
    {/each}
  {/if}
</div>

{#if addMenuAnchor}
  <Menu anchor={addMenuAnchor} sections={addMenuSections} onclose={() => (addMenuAnchor = null)} />
{/if}

{#if showRegistry}
  <div class="modal" role="dialog" aria-modal="true" aria-label={tr("ACP-register", "ACP registry")}>
    <div class="sheet registry-sheet">
      <div class="sheet-head">
        <h3>{tr("ACP-register", "ACP registry")}</h3>
        <p class="sheet-sub">{tr("Agents die ACP spreken, van agentclientprotocol.com.", "Agents that speak ACP, from agentclientprotocol.com.")}</p>
      </div>

      <div class="step">
        <div class="step-head">
          <span class="step-num" class:done={chosenEntry !== null}>1</span>
          <span class="step-title">{tr("Kies een agent", "Pick an agent")}</span>
        </div>
        <input
          type="search"
          class="search-input"
          placeholder={tr("Zoek een agent", "Find an agent")}
          bind:value={registryQuery}
          disabled={installing}
        />
        {#if registryLoading}
          <p class="muted loading-box">{tr("Laden…", "Loading…")}</p>
        {:else if registryError}
          <p class="warn">{registryError}</p>
        {:else}
          <div class="pick-list" role="listbox" aria-label={tr("ACP-register", "ACP registry")}>
            {#each shownRegistry as entry (entry.id)}
              <button
                type="button"
                role="option"
                class="pick-row"
                class:selected={chosenEntry?.id === entry.id}
                aria-selected={chosenEntry?.id === entry.id}
                disabled={!entry.supported || installing}
                onclick={() => {
                  chosenEntry = entry;
                  installError = null;
                }}
              >
                <span class="pick-name">{entry.name}</span>
                <span class="pick-detail">{registryDetail(entry)}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>

      <div class="step">
        <div class="step-head">
          <span class="step-num">2</span>
          <span class="step-title">{tr("Bekijk wat er draait", "Check what runs")}</span>
        </div>
        <p class="check-detail mono-wrap">{registryCheckDetail}</p>
        {#if installError}
          <p class="err">{installError}</p>
        {/if}
      </div>

      <div class="sheet-foot">
        {#if installing}
          <span class="busy-line">{tr("Downloaden en controleren…", "Downloading and checking…")}</span>
        {/if}
        <span class="spacer"></span>
        <button type="button" class="ghost" disabled={installing} onclick={closeRegistry}>{tr("Annuleer", "Cancel")}</button>
        <button
          type="button"
          class="primary"
          disabled={!chosenEntry?.supported || installing}
          onclick={confirmRegistry}
        >
          {chosenEntry && !chosenEntry.command && chosenEntry.binary
            ? tr("Installeer", "Install")
            : tr("Toevoegen", "Add")}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showManual}
  <div class="modal" role="dialog" aria-modal="true" aria-label={tr("Een ACP-agent toevoegen", "Add an ACP agent")}>
    <div class="sheet manual-sheet">
      <div class="sheet-head">
        <h3>{tr("Een ACP-agent toevoegen", "Add an ACP agent")}</h3>
        <p class="sheet-sub">{tr("Een naam en de opdracht die zijn ACP-server start.", "A name and the command that starts its ACP server.")}</p>
      </div>

      <div class="step">
        <div class="step-head">
          <span class="step-num" class:done={manualName.trim().length > 0}>1</span>
          <label class="step-title" for="acp-manual-name">{tr("Naam", "Name")}</label>
        </div>
        <!-- svelte-ignore a11y_autofocus -->
        <input
          id="acp-manual-name"
          autofocus
          placeholder={tr("Mijn agent", "My agent")}
          bind:value={manualName}
          disabled={manualSaving}
        />
      </div>

      <div class="step">
        <div class="step-head">
          <span class="step-num" class:done={parsedManual !== null}>2</span>
          <label class="step-title" for="acp-manual-cmd">{tr("Opdracht", "Command")}</label>
        </div>
        <input
          id="acp-manual-cmd"
          class="mono-input"
          placeholder="npx -y @vendor/agent-acp@1.0.0"
          value={manualCommand}
          disabled={manualSaving}
          oninput={(e) => {
            manualCommand = e.currentTarget.value;
            manualCheckOk = null;
            manualCheckErr = null;
            manualError = null;
          }}
        />
        {#if manualCommand.length > 0 && parsedManual === null}
          <p class="warn">{tr("Er staat een aanhalingsteken open.", "A quote is left open.")}</p>
        {/if}
      </div>

      <div class="step">
        <div class="step-head">
          <span class="step-num" class:done={manualCheckOk !== null}>3</span>
          <span class="step-title">{tr("Opdracht controleren", "Check the command")}</span>
        </div>
        <p class="check-detail">
          {tr(
            "Nook zoekt het programma zoals een sessie het start, via je login-shell.",
            "Nook looks for the program the way a session starts it, through your login shell.",
          )}
        </p>
        <div class="check-actions">
          <button type="button" class="small" disabled={parsedManual === null || manualChecking} onclick={checkManualCommand}>
            {manualChecking ? tr("Controleren…", "Checking…") : tr("Opdracht controleren", "Check the command")}
          </button>
        </div>
        {#if manualCheckOk}<p class="ok">{manualCheckOk}</p>{/if}
        {#if manualCheckErr}<p class="warn">{manualCheckErr}</p>{/if}
        {#if manualError}<p class="err">{manualError}</p>{/if}
      </div>

      <div class="sheet-foot">
        <span class="spacer"></span>
        <button type="button" class="ghost" disabled={manualSaving} onclick={closeManual}>{tr("Annuleer", "Cancel")}</button>
        <button type="button" class="primary" disabled={!canAddManual} onclick={confirmManual}>
          {tr("Toevoegen", "Add")}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .acp-head { display: flex; align-items: center; justify-content: space-between; gap: var(--space-12); margin-top: var(--space-24); }
  .acp-head h3 { margin: 0; }
  .head-action { display: inline-flex; align-items: center; gap: var(--space-6); padding: var(--space-4) var(--space-10); border: 1px solid var(--separator); border-radius: var(--radius-control); background: transparent; color: var(--paper); font: var(--text-detail); cursor: pointer; }
  .head-action:hover { background: var(--row-hover); }

  .empty-card { padding: var(--space-16); display: flex; flex-direction: column; gap: var(--space-4); }
  .empty-title { font: var(--text-emphasis); color: var(--paper); }
  .empty-detail { font: var(--text-detail); color: var(--text2); line-height: 1.4; }

  .kv { display: flex; justify-content: space-between; align-items: flex-start; gap: var(--space-16); font: var(--text-body); color: var(--paper); }
  .mono { font: var(--text-code); color: var(--text2); word-break: break-all; user-select: text; text-align: right; }
  .text { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .ok { margin: 0; font: var(--text-detail); color: var(--mint); }
  .warn { margin: 0; font: var(--text-detail); color: var(--amber); }
  .err { margin: 0; font: var(--text-detail); color: var(--coral); }
  .muted { margin: 0; font: var(--text-detail); color: var(--text2); }

  .modal { position: fixed; inset: 0; background: color-mix(in srgb, black 55%, transparent); display: flex; align-items: center; justify-content: center; z-index: 20; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-composer); padding: var(--space-20); max-height: 86vh; display: flex; flex-direction: column; gap: var(--space-16); overflow: hidden; }
  .registry-sheet { width: min(560px, 92vw); }
  .manual-sheet { width: min(460px, 92vw); }
  .sheet-head { display: flex; flex-direction: column; gap: var(--space-4); }
  .sheet-head h3 { margin: 0; color: var(--paper); font: var(--text-title); }
  .sheet-sub { margin: 0; color: var(--text2); font: var(--text-detail); }

  .step { display: flex; flex-direction: column; gap: var(--space-8); min-height: 0; }
  .step-head { display: flex; align-items: center; gap: var(--space-8); }
  .step-num { width: 20px; height: 20px; border-radius: 50%; display: grid; place-items: center; background: var(--surface); border: 1px solid var(--separator); color: var(--text2); font: var(--text-caption); flex: none; }
  .step-num.done { background: var(--mint); border-color: var(--mint); color: var(--graphite); }
  .step-title { font: var(--text-emphasis); color: var(--paper); }

  .search-input, .manual-sheet input { width: 100%; box-sizing: border-box; }
  .mono-input { font-family: var(--mono); }
  .loading-box { padding: var(--space-24) 0; text-align: center; }

  .pick-list { display: flex; flex-direction: column; gap: var(--space-4); max-height: 240px; overflow-y: auto; padding-right: var(--space-4); }
  .pick-row { display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-2); padding: var(--space-10) var(--space-12); border: 1px solid var(--separator); border-radius: var(--radius-control); background: var(--surface); text-align: left; cursor: pointer; width: 100%; }
  .pick-row:hover:not(:disabled) { background: var(--row-hover); }
  .pick-row.selected { border-color: var(--iris); background: color-mix(in srgb, var(--iris) 14%, var(--surface)); }
  .pick-row:disabled { opacity: 0.5; cursor: not-allowed; }
  .pick-name { font: var(--text-emphasis); color: var(--paper); }
  .pick-detail { font: var(--text-detail); color: var(--text2); line-height: 1.35; }

  .check-detail { margin: 0; font: var(--text-detail); color: var(--text2); line-height: 1.4; }
  .mono-wrap { word-break: break-all; }
  .check-actions { display: flex; align-items: center; gap: var(--space-8); }
  .small { font: var(--text-detail); }

  .sheet-foot { display: flex; align-items: center; gap: var(--space-8); padding-top: var(--space-8); border-top: 1px solid var(--separator); }
  .busy-line { font: var(--text-detail); color: var(--text2); }
  .spacer { flex: 1; }
</style>
