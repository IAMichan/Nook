<script lang="ts">
  // Settings › Coding agents (`AgentsSettingsPanel` on the Mac): every agent in one card, the agents on the left (logo,
  // name, version, and where it stands in a dot and a word) and the one picked on the right with its own scroll: its
  // link with Nook (each settings file a row with a switch that shows the change and makes a backup before writing),
  // its program and update, how Nook talks to it (Antigravity's ACP server), and its accounts. Skills and Usage & costs
  // are the page's other subjects (AgentsSkills.svelte, AgentsUsage.svelte).
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { ask } from "../../lib/confirm.svelte";
  import { agentApi, agentNames, type AgentKind, type AgentProfile, type Integration, type LinkPreview } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { nook } from "../../lib/state.svelte";
  import { workspaceApi, type RunProvider, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import DiffView from "../agents/DiffView.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ConnectionRow from "./ConnectionRow.svelte";
  import AgentUpdates from "../agents/AgentUpdates.svelte";

  interface AgentVersionInfo {
    provider: RunProvider;
    executable: string | null;
    version: string | null;
    installCommand: string;
  }

  interface AntigravitySetup {
    supported: boolean;
    installed: boolean;
    busy: boolean;
    version: string;
    downloadBytes: number;
  }

  interface AntigravityProgress {
    phase: "downloading" | "verifying" | "unpacking" | "checking" | "done" | "failed";
    fraction: number;
    error?: string | null;
  }

  interface AgentEntry {
    id: string;
    name: string;
    provider: RunProvider | null;
    agentKind: AgentKind | null;
    integrations: Integration[];
    extraIntegrations: Integration[];
  }

  type Tone = "linked" | "attention" | "idle";

  const RUNNABLE_ORDER: RunProvider[] = ["claude", "codex", "gemini", "antigravity", "opencode", "cursor", "grok"];

  /** Nil until you pick one, which shows the first linked agent (as on the Mac). */
  let selectedId = $state<string | null>(null);

  let integrations = $state<Integration[]>([]);
  let profiles = $state<AgentProfile[]>([]);
  let versions = $state<Record<string, AgentVersionInfo>>({});
  let checkingVersions = $state(false);
  let wsSettings = $state<WorkspaceSettings | null>(null);

  let pending = $state<LinkPreview | null>(null);
  let status = $state<string | null>(null);
  let error = $state<string | null>(null);
  let copiedPath = $state(false);
  let adding = $state(false);
  let newLabel = $state<Record<string, string>>({});
  let keyInput = $state<Record<string, string>>({});

  let agSetup = $state<AntigravitySetup | null>(null);
  let agProgress = $state<AntigravityProgress | null>(null);

  const local = $derived(nook.info?.capabilities.localAgents ?? false);

  async function loadVersions() {
    checkingVersions = true;
    try {
      versions = await invoke<Record<string, AgentVersionInfo>>("workspace_agent_versions");
    } catch {
      // Older builds have no version command; the list then shows what the workspace found.
    } finally {
      checkingVersions = false;
    }
  }

  async function loadAntigravity() {
    agSetup = await invoke<AntigravitySetup>("antigravity_setup").catch(() => null);
  }

  async function load() {
    if (!local) return;
    const [ints, profs] = await Promise.all([agentApi.integrations(), agentApi.profiles()]);
    integrations = ints;
    profiles = profs;
    agents.loadHistory();
    workspace.start().then(() => {
      wsSettings = workspace.settings ? { ...workspace.settings, defaultModels: { ...workspace.settings.defaultModels } } : null;
    });
    loadVersions();
    loadAntigravity();
  }

  $effect(() => {
    load();
    const off = listen<AntigravityProgress>("antigravity-install", (e) => {
      agProgress = e.payload;
      if (e.payload.phase === "done" || e.payload.phase === "failed") {
        loadAntigravity();
        loadVersions();
        workspace.refresh();
      }
    });
    return () => {
      off.then((f) => f());
    };
  });

  const agentEntries = $derived.by<AgentEntry[]>(() => {
    const entries: AgentEntry[] = [];
    const claimed = new Set<string>();
    for (const provider of RUNNABLE_ORDER) {
      const kind = provider as AgentKind;
      const name = workspace.provider(provider)?.name ?? agentNames[kind] ?? provider;
      const own = integrations.filter((i) => !i.profileId && (i.agent === kind || (!i.agent && i.title === name)));
      for (const i of own) claimed.add(i.target);
      entries.push({ id: provider, name, provider, agentKind: kind, integrations: own, extraIntegrations: integrations.filter((i) => !!i.profileId && i.agent === kind) });
    }
    // The agents Nook only follows through their settings file (Copilot CLI, Muse Code, Amp, Hermes, …).
    for (const i of integrations) {
      if (i.profileId || claimed.has(i.target)) continue;
      entries.push({ id: `follow:${i.target}`, name: i.title, provider: null, agentKind: i.agent, integrations: [i], extraIntegrations: [] });
    }
    return entries;
  });

  const isLinked = (i: Integration) => i.state.kind === "installed" || i.state.kind === "outdated";

  const selectedEntry = $derived(
    agentEntries.find((e) => e.id === selectedId) ?? agentEntries.find((e) => e.integrations.some(isLinked)) ?? agentEntries[0] ?? null,
  );

  function linkWord(i: Integration): string {
    switch (i.state.kind) {
      case "installed": return tr("Gekoppeld", "Linked");
      case "outdated": return tr("Verouderd", "Outdated");
      case "unreadable": return tr("Instellingen niet leesbaar", "Can't read its settings");
      default: return tr("Niet gekoppeld", "Not linked");
    }
  }

  function entryExecutable(entry: AgentEntry): string | null {
    if (!entry.provider) return null;
    return versions[entry.provider]?.executable ?? workspace.provider(entry.provider)?.executable ?? null;
  }

  /** Where the agent stands, in a word and a color: a link to renew, linked, found on this computer, or not yet. */
  function standing(entry: AgentEntry): { tone: Tone; label: string } {
    if (entry.integrations.some((i) => i.state.kind === "outdated")) return { tone: "attention", label: tr("Verouderd", "Outdated") };
    if (entry.integrations.some((i) => i.state.kind === "installed")) return { tone: "linked", label: tr("Gekoppeld", "Linked") };
    if (entry.integrations.length === 0 && entry.provider) {
      return entryExecutable(entry)
        ? { tone: "linked", label: tr("Geïnstalleerd", "Installed") }
        : { tone: "idle", label: tr("Niet gevonden op deze computer", "Not found on this computer") };
    }
    return { tone: "idle", label: tr("Niet gekoppeld", "Not linked") };
  }

  function entryVersion(entry: AgentEntry): string | null {
    if (!entry.provider) return null;
    return versions[entry.provider]?.version ?? null;
  }

  function entryInstallCommand(entry: AgentEntry): string {
    if (!entry.provider) return "";
    return versions[entry.provider]?.installCommand ?? workspace.provider(entry.provider)?.installCommand ?? "";
  }

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
        (change.install
          ? tr("{title}: gekoppeld.", "{title}: linked.", { title: change.title })
          : tr("{title}: ontkoppeld.", "{title}: unlinked.", { title: change.title })) +
        (backup ? " " + tr("Backup: {path}.", "Backup: {path}.", { path: backup }) : "") +
        (change.install && change.title !== "Claude-abonnement in de balk"
          ? " " + tr("Start de agent opnieuw zodat het werkt.", "Restart the agent so it takes effect.")
          : "");
    } catch (e) {
      error = String(e);
    }
    load();
  }

  function cancel() {
    if (pending) agentApi.discardLink(pending.id);
    pending = null;
  }

  async function saveDefaultModel(provider: RunProvider, value: string) {
    if (!wsSettings) return;
    error = null;
    wsSettings.defaultModels[provider] = value.trim();
    try {
      await workspaceApi.saveSettings($state.snapshot(wsSettings));
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  async function copyCliPath(path: string) {
    try {
      await navigator.clipboard.writeText(path);
      copiedPath = true;
      setTimeout(() => (copiedPath = false), 1500);
    } catch {
      // No clipboard: the path stays selectable.
    }
  }

  async function revealPath(path: string) {
    error = null;
    try {
      await invoke("workspace_reveal_path", { path });
    } catch (e) {
      error = String(e);
    }
  }

  async function checkUpdates() {
    error = null;
    await Promise.all([loadVersions(), workspace.refresh(), loadAntigravity()]);
  }

  function installAntigravity() {
    agProgress = { phase: "downloading", fraction: 0 };
    invoke("antigravity_install").catch((e) => (agProgress = { phase: "failed", fraction: 0, error: String(e) }));
  }

  async function uninstallAntigravity() {
    if (!(await ask({
      question: tr("“{title}” verwijderen?", "Remove “{title}”?", { title: "Antigravity" }),
      detail: tr("Nook verwijdert de gedownloade server. Antigravity-sessies starten pas weer als je hem opnieuw downloadt; je accounts en de koppeling blijven.", "Nook deletes the downloaded server. Antigravity sessions can't start until you download it again; your accounts and its link stay."),
      confirmTitle: tr("Verwijderen", "Remove"),
    }))) return;
    error = null;
    try {
      await invoke("antigravity_uninstall");
      await loadAntigravity();
      await loadVersions();
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  async function addProfile(kind: AgentKind) {
    try {
      await agentApi.addProfile(kind, newLabel[kind] ?? "");
      newLabel[kind] = "";
      adding = false;
    } catch (e) {
      error = String(e);
    }
    load();
  }

  async function removeProfile(p: AgentProfile) {
    if (!(await ask({
      question: tr("{title} uit Nook halen?", "Remove {title} from Nook?", { title: p.title }),
      detail: tr("De map {folder} en de inlog blijven op je computer staan.", "The folder {folder} and the login stay on your computer.", { folder: p.displayHome }),
      confirmTitle: tr("Haal weg", "Remove"),
    }))) return;
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

  function account(p: AgentProfile): string | null {
    const a = agents.history?.accounts[p.id];
    if (!a) return null;
    return [a.name, a.organization, a.plan].filter(Boolean).join(" · ");
  }

  function profileName(p: AgentProfile): string {
    return p.label || (p.home ? p.title : tr("Hoofdaccount", "Main account"));
  }

  const agWorking = $derived(!!agProgress && agProgress.phase !== "done" && agProgress.phase !== "failed");
  const agStatus = $derived.by(() => {
    if (agProgress?.phase === "downloading" && agWorking) return tr("Downloaden ({n}%)", "Downloading ({n}%)", { n: Math.round(agProgress.fraction * 100) });
    if (agProgress?.phase === "verifying") return tr("Controleren…", "Verifying…");
    if (agProgress?.phase === "unpacking") return tr("Uitpakken…", "Unpacking…");
    if (agProgress?.phase === "checking") return tr("Proefstart…", "Test start…");
    if (agProgress?.phase === "failed") return tr("Installeren mislukt", "Install failed");
    return agSetup?.installed ? tr("Geïnstalleerd", "Installed") : tr("Niet geïnstalleerd", "Not installed");
  });
</script>

{#if !local}
  <p class="muted">
    {tr(
      "Coding-agents draaien op je computer, niet op je telefoon. Open Nook op je Windows- of Linux-computer om Claude Code, Codex en de andere agents te koppelen; op de telefoon zie je ze via de companion.",
      "Coding agents run on your computer, not on your phone. Open Nook on your Windows or Linux computer to link Claude Code, Codex and the other agents; on your phone you see them through the companion.",
    )}
  </p>
{:else}
  {#if status}<p class="ok note">{status}</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}

  <h3>{tr("Je agents", "Your agents")}</h3>
  <p class="section-info">{tr("Koppelen zet de hooks van Nook in de eigen instellingen van een agent, zodat zijn voortgang en vragen in Nook verschijnen. De schakelaar koppelt of ontkoppelt; je ziet de wijziging voordat er iets wordt geschreven.", "Linking adds Nook's hooks to an agent's own settings, so its progress and questions show in Nook. The switch links or unlinks it; you see the change before anything is written.")}</p>

  <div class="panel">
    <div class="agent-list" role="listbox" aria-label={tr("Je agents", "Your agents")}>
      {#each agentEntries as entry (entry.id)}
        {@const place = standing(entry)}
        {@const ver = entryVersion(entry)}
        <button type="button" role="option" class="list-item" class:selected={selectedEntry?.id === entry.id} aria-selected={selectedEntry?.id === entry.id} onclick={() => (selectedId = entry.id)}>
          <span class="mark"><AgentMark agent={entry.name} size={24} /></span>
          <span class="item-body">
            <span class="item-head">
              <span class="item-name">{entry.name}</span>
              {#if ver}<span class="ver">{ver}</span>{/if}
            </span>
            <span class="place {place.tone}"><span class="dot"></span>{place.label}</span>
          </span>
        </button>
      {/each}
    </div>

    {#if selectedEntry}
      {@const entry = selectedEntry}
      {@const place = standing(entry)}
      {@const ver = entryVersion(entry)}
      {@const exe = entryExecutable(entry)}
      {@const installCmd = entryInstallCommand(entry)}
      <div class="agent-detail">
        {#key entry.id}
          <div class="detail-head">
            <span class="mark"><AgentMark agent={entry.name} size={32} /></span>
            <span class="head-text">
              <span class="detail-title">{entry.name}</span>
              <span class="place {place.tone}"><span class="dot"></span>{place.label}</span>
            </span>
            {#if ver}<span class="head-ver">{ver}</span>{/if}
          </div>

          {#if entry.integrations.length > 0}
            <h3>{tr("Koppelen met Nook", "Link with Nook")}</h3>
            <p class="section-info">{tr("Nook zet zijn hooks in de eigen instellingen van de agent, zodat voortgang en vragen bij Nook komen. De schakelaar koppelt of ontkoppelt; je ziet de wijziging eerst.", "Nook adds its hooks to the agent’s own settings, so its progress and questions reach Nook. The switch links or unlinks it; you see the change first.")}</p>
            <div class="group">
              {#each entry.integrations as i (i.target)}
                <ConnectionRow
                  title={i.title}
                  status={i.state.kind === "unreadable" ? `${linkWord(i)} · ${i.state.detail}` : isLinked(i) ? `${linkWord(i)} · ${i.path}` : linkWord(i)}
                  attention={i.state.kind === "outdated" ? "amber" : i.state.kind === "unreadable" ? "coral" : null}
                  on={i.state.kind === "unreadable" ? null : isLinked(i)}
                  onToggle={(on) => prepare(i, on)}
                  menu={i.state.kind === "outdated" ? [{ label: tr("Koppeling bijwerken…", "Update link…"), onselect: () => prepare(i, true) }] : []}
                >
                  {#snippet icon()}<AgentMark agent={i.title} size={22} />{/snippet}
                  {#snippet expanded()}
                    {#if i.detail}<p class="text">{i.detail}</p>{/if}
                    <div class="kv"><span>{tr("Instellingenbestand", "Settings file")}</span><span class="mono">{i.path}</span></div>
                    {#if i.state.kind === "outdated"}
                      <p class="warn">{tr("Gekoppeld met een oudere versie: werk bij voor toestemming en vragen in de balk", "Linked with an older version: update for permissions and questions in the bar")}</p>
                      <div><button class="small" onclick={() => prepare(i, true)}>{tr("Koppeling bijwerken…", "Update link…")}</button></div>
                    {:else if i.state.kind === "unreadable"}
                      <p class="err">{i.state.detail}</p>
                    {/if}
                    <p class="text">{tr("Koppelen of ontkoppelen laat eerst precies zien wat er in dit bestand verandert, en bewaart er een reservekopie van.", "Linking or unlinking first shows the exact change to this file, and keeps a backup of it.")}</p>
                  {/snippet}
                </ConnectionRow>
              {/each}
            </div>
            <p class="note">
              {tr(
                "Nook laat eerst precies zien wat er verandert en maakt een backup voordat er iets wordt geschreven. Draait Nook niet, dan doen de koppelingen niets. Toestemming geven vanuit de balk kan bij Claude Code en Codex; bij de andere agents beslist Nook nooit iets.",
                "Nook first shows exactly what changes and makes a backup before anything is written. If Nook isn't running, the links do nothing. Granting permission from the bar works for Claude Code and Codex; for the other agents Nook never decides anything.",
              )}
            </p>
          {/if}

          {#if entry.provider === "antigravity" && agSetup?.supported}
            <h3>{tr("Hoe Nook ermee praat", "How Nook talks to it")}</h3>
            <div class="group">
              <ConnectionRow
                title={tr("ACP-server van Antigravity", "Antigravity ACP server")}
                version={agSetup.installed ? agSetup.version : null}
                status={agStatus + (agProgress?.phase === "failed" && agProgress.error ? ` · ${agProgress.error}` : !agSetup.installed && !agWorking ? ` · ${Math.round(agSetup.downloadBytes / 1_000_000)} MB` : "")}
                attention={agProgress?.phase === "failed" ? "coral" : null}
                menu={!agSetup.installed && !agWorking ? [{ label: tr("Installeren", "Install"), icon: "download", onselect: installAntigravity }] : []}
                danger={agSetup.installed && !agWorking ? [{ label: tr("Verwijderen…", "Remove…"), icon: "trash-2", onselect: uninstallAntigravity }] : []}
              >
                {#snippet icon()}<AgentMark agent="Antigravity" size={22} />{/snippet}
                {#snippet expanded()}
                  <p class="text">
                    {tr(
                      "Antigravity draait in Nook op Google's eigen ACP-server. Eenmalig installeren ({size} download).",
                      "Antigravity runs in Nook on Google's own ACP server. Install it once ({size} download).",
                      { size: `${Math.round(agSetup!.downloadBytes / 1_000_000)} MB` },
                    )}
                  </p>
                  {#if agWorking && agProgress?.phase === "downloading"}
                    <progress max="1" value={agProgress.fraction}></progress>
                  {:else if !agSetup!.installed && !agWorking}
                    <div><button class="small" onclick={installAntigravity}>{tr("Installeren", "Install")}</button></div>
                  {/if}
                {/snippet}
              </ConnectionRow>
            </div>
          {/if}

          {#if !entry.provider}
            <p class="note follow">{tr("Nook volgt {name} via zijn instellingenbestand: je ziet voortgang en vragen in Nook, terwijl sessies in de eigen app starten.", "Nook follows {name} through its settings file: you see its progress and questions in Nook, while its sessions start in its own app.", { name: entry.name })}</p>
          {:else}
            {@const provider = entry.provider}
            <h3>{tr("Updates", "Updates")}</h3>
            <p class="section-info">{tr("Het programma van elke agent en de versie. Bijwerken draait zijn installatieopdracht in een terminal; lopende sessies houden de versie waarmee ze begonnen.", "Each agent's program and its version. Update runs its install command in a terminal; running sessions keep the version they started with.")}</p>
            <div class="group">
              <ConnectionRow
                title={entry.name}
                version={ver}
                status={exe ? tr("Geïnstalleerd", "Installed") : tr("Niet gevonden op deze computer", "Not found on this computer")}
                menu={[
                  ...(installCmd ? [{ label: exe ? tr("Bijwerken", "Update") : tr("Installeren", "Install"), icon: "download", onselect: () => agentApi.runInTerminal(installCmd) }] : []),
                  { label: checkingVersions ? tr("Controleren…", "Checking…") : tr("Zoek naar updates", "Check for updates"), icon: "refresh-cw", disabled: checkingVersions, onselect: checkUpdates },
                ]}
              >
                {#snippet icon()}<AgentMark agent={entry.name} size={22} />{/snippet}
                {#snippet expanded()}
                  {#if exe}
                    <div class="field">
                      <span class="field-title">{tr("CLI-pad", "CLI path")}</span>
                      <span class="mono">{exe}</span>
                      <span class="inline">
                        <button class="small" onclick={() => copyCliPath(exe)}>{copiedPath ? tr("Gekopieerd", "Copied") : tr("Kopiëren", "Copy")}</button>
                        <button class="small" onclick={() => revealPath(exe)}>{tr("Map openen", "Open folder")}</button>
                      </span>
                    </div>
                  {/if}
                  {#if installCmd}
                    <div class="field">
                      <span class="field-title">{exe ? tr("Bijwerken", "Update") : tr("Installeren", "Install")}</span>
                      <span class="mono">{installCmd}</span>
                      <span class="inline"><button class="small" onclick={() => agentApi.runInTerminal(installCmd)}>{tr("Draai in terminal", "Run in terminal")}</button></span>
                    </div>
                  {/if}
                  {#if wsSettings}
                    <label class="field">
                      <span class="field-title">{tr("Standaardmodel", "Default model")}</span>
                      <input class="model-input" placeholder={tr("standaard", "default")} value={wsSettings.defaultModels[provider] ?? ""} onchange={(e) => saveDefaultModel(provider, e.currentTarget.value)} />
                      <span class="text">{tr("Leeg laat de agent zijn eigen standaardmodel kiezen.", "Leave empty to let the agent pick its own default model.")}</span>
                    </label>
                  {/if}
                {/snippet}
              </ConnectionRow>
            </div>
          {/if}

          {#if entry.agentKind === "claude" || entry.agentKind === "codex" || entry.agentKind === "gemini"}
            {@const kind = entry.agentKind}
            <div class="section-head">
              <h3>{tr("Accounts", "Accounts")}</h3>
              <button type="button" class="head-action" onclick={() => (adding = !adding)}><Ico name="plus" size={14} />{tr("Account toevoegen", "Add account")}</button>
            </div>
            <div class="group">
              {#if adding}
                <div class="row add-row">
                  <!-- svelte-ignore a11y_autofocus -->
                  <input autofocus placeholder={tr("Naam van een extra account, bijvoorbeeld Werk", "Name of an extra account, for example Work")} bind:value={newLabel[kind]} onkeydown={(e) => e.key === "Enter" && addProfile(kind)} />
                  <button class="primary" onclick={() => addProfile(kind)}>{tr("Voeg account toe", "Add account")}</button>
                </div>
              {/if}
              {#each profiles.filter((p) => p.kind === kind) as p (p.id)}
                {@const acc = account(p)}
                {@const links = entry.extraIntegrations.filter((i) => i.profileId === p.id)}
                <ConnectionRow
                  title={profileName(p)}
                  status={[p.preferred ? tr("Standaard", "Default") : null, acc ?? (kind === "gemini" ? null : tr("Nog niet ingelogd", "Not yet logged in"))].filter(Boolean).join(" · ")}
                  attention={acc || kind === "gemini" ? null : "amber"}
                  menu={[
                    { label: tr("Log in…", "Sign in…"), icon: "terminal", onselect: () => agentApi.runInTerminal(p.loginCommand) },
                    ...(p.preferred ? [] : [{ label: tr("Maak standaard", "Make default"), icon: "star", onselect: () => agentApi.preferProfile(p.id).then(load) }]),
                  ]}
                  danger={p.home ? [{ label: tr("Account uit Nook halen…", "Remove account from Nook…"), icon: "trash-2", onselect: () => removeProfile(p) }] : []}
                >
                  {#snippet icon()}<AgentMark agent={entry.name} size={22} />{/snippet}
                  {#snippet expanded()}
                    {#if p.displayHome}<div class="kv"><span>{tr("Map", "Folder")}</span><span class="mono">{p.displayHome}</span></div>{/if}
                    {#if kind === "claude"}
                      <div class="kv">
                        <span>{tr("Methode", "Method")}</span>
                        <select value={p.auth ?? "cli"} onchange={(e) => agentApi.setProfileAuth(p.id, e.currentTarget.value as "cli" | "apiKey").then(load)}>
                          <option value="cli">{tr("Abonnement (inloggen)", "Subscription (sign in)")}</option>
                          <option value="apiKey">{tr("API-sleutel", "API key")}</option>
                        </select>
                      </div>
                      {#if p.auth === "apiKey"}
                        <div class="inline key">
                          <input type="password" placeholder={p.hasKey ? tr("Sleutel staat in de kluis", "Key is in the keychain") : "sk-ant-…"} bind:value={keyInput[p.id]} />
                          <button class="small" onclick={() => saveKey(p)}>{keyInput[p.id] ? tr("Bewaar", "Save") : p.hasKey ? tr("Wis", "Clear") : tr("Bewaar", "Save")}</button>
                        </div>
                      {/if}
                    {/if}
                    {#each links as i (i.target + i.profileId)}
                      <div class="kv">
                        <span class="link-text"><span>{i.title}</span><span class="text">{linkWord(i)}{isLinked(i) ? ` · ${i.path}` : ""}</span></span>
                        {#if i.state.kind === "installed"}
                          <button class="small" onclick={() => prepare(i, false)}>{tr("Ontkoppel…", "Unlink…")}</button>
                        {:else if i.state.kind !== "unreadable"}
                          <button class="small" onclick={() => prepare(i, true)}>{i.state.kind === "outdated" ? tr("Werk bij…", "Update…") : tr("Koppel…", "Link…")}</button>
                        {/if}
                      </div>
                    {/each}
                    <div class="inline">
                      <button class="small" onclick={() => agentApi.runInTerminal(p.loginCommand)}>{tr("Log in…", "Sign in…")}</button>
                      {#if !p.preferred}<button class="small" onclick={() => agentApi.preferProfile(p.id).then(load)}>{tr("Maak standaard", "Make default")}</button>{/if}
                    </div>
                  {/snippet}
                </ConnectionRow>
              {/each}
              {#each entry.extraIntegrations.filter((i) => !profiles.some((p) => p.id === i.profileId)) as i (i.target + i.profileId)}
                <ConnectionRow title={i.title} status={linkWord(i)} on={i.state.kind === "unreadable" ? null : isLinked(i)} onToggle={(on) => prepare(i, on)}>
                  {#snippet icon()}<AgentMark agent={entry.name} size={22} />{/snippet}
                </ConnectionRow>
              {/each}
            </div>
            <p class="faint note">
              {tr(
                "Elk account heeft een eigen map (bijvoorbeeld ~/.claude-werk) met een eigen inlog, zodat privé en werk naast elkaar kunnen. Een API-sleutel staat alleen in de kluis van je systeem, nooit in een bestand.",
                "Each account has its own folder (for example ~/.claude-work) with its own login, so personal and work can live side by side. An API key is only kept in your system's keychain, never in a file.",
              )}
            </p>
          {/if}
        {/key}
      </div>
    {/if}
  </div>
  <!-- Every agent program with its version and Update (`AgentUpdatesSection`). -->
  <AgentUpdates />
{/if}

{#if pending}
  <div class="modal" role="dialog" aria-modal="true">
    <div class="sheet">
      <h3>
        {pending.install
          ? tr("Koppel {title}", "Link {title}", { title: pending.title })
          : tr("Ontkoppel {title}", "Unlink {title}", { title: pending.title })}
      </h3>
      {#if pending.unchanged}
        <p class="muted">{tr("Er verandert niets.", "Nothing changes.")}</p>
      {:else}
        <p class="muted small">
          {tr(
            "Dit verandert in {path}. Je eigen instellingen blijven staan; er komt eerst een backup naast het bestand.",
            "This changes in {path}. Your own settings stay; a backup is made next to the file first.",
            { path: pending.path },
          )}
        </p>
        <DiffView lines={pending.preview} max={360} />
      {/if}
      <div class="inline end">
        <button class="ghost" onclick={cancel}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={pending.unchanged} onclick={write}>
          {pending.install ? tr("Koppel", "Link") : tr("Ontkoppel", "Unlink")}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  /* The one card: the list and the agent picked, each with its own scroll (the Mac's 540 pt card, list 250 pt wide). */
  .panel {
    display: grid;
    grid-template-columns: 250px minmax(0, 1fr);
    height: 540px;
    margin-top: var(--space-8);
    background: var(--surface);
    border: 1px solid var(--separator);
    border-radius: var(--radius-panel);
    overflow: hidden;
  }
  .agent-list { overflow-y: auto; scrollbar-width: none; border-right: 1px solid var(--separator); }
  .list-item {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    width: 100%;
    height: auto;
    text-align: left;
    border: none;
    border-radius: 0;
    background: transparent;
    padding: var(--space-12) var(--space-16);
  }
  .list-item:hover { background: var(--row-hover); }
  .list-item.selected { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .mark { flex: none; display: grid; }
  .item-body { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; flex: 1; }
  .item-head { display: flex; align-items: baseline; gap: var(--space-4); min-width: 0; }
  .item-name { font: var(--text-emphasis); color: var(--paper); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .ver { font: var(--text-caption); font-family: var(--mono); color: var(--text3); flex: none; }

  .place { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-detail); color: var(--text2); white-space: nowrap; }
  .place .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--text3); flex: none; }
  .place.linked .dot { background: var(--mint); }
  .place.attention .dot { background: var(--amber); }

  .agent-detail { overflow-y: auto; padding: var(--space-16) var(--space-24) var(--space-24); min-width: 0; }
  .detail-head { display: flex; align-items: center; gap: var(--space-16); }
  .head-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .detail-title { font: var(--text-heading); color: var(--paper); }
  .head-ver { font: var(--text-code); color: var(--text3); user-select: text; }
  .agent-detail > h3 { margin-top: var(--space-24); }
  .agent-detail .section-head { margin-top: var(--space-24); }
  .agent-detail .group { margin-top: var(--space-8); }
  .note.follow { margin-top: var(--space-24); }

  .text { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .warn { margin: 0; font: var(--text-detail); color: var(--amber); }
  .kv { display: flex; justify-content: space-between; align-items: center; gap: var(--space-16); font: var(--text-body); color: var(--paper); }
  .mono { font: var(--text-code); color: var(--text2); word-break: break-all; user-select: text; }
  .kv .mono { text-align: right; }
  .link-text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  .field { display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-4); }
  .field-title { font: var(--text-emphasis); color: var(--paper); }
  .inline { display: flex; align-items: center; gap: var(--space-8); flex-wrap: wrap; }
  .small { font: var(--text-detail); }
  .key input { width: 220px; }
  .model-input { width: 220px; }
  .add-row { flex-wrap: nowrap; }
  .add-row input { flex: 1; }
  progress { width: 160px; accent-color: var(--paper); }
  .ok { color: var(--mint); }
  .err { color: var(--coral); font: var(--text-detail); }

  .modal { position: fixed; inset: 0; background: color-mix(in srgb, black 55%, transparent); display: flex; align-items: center; justify-content: center; z-index: 20; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-composer); padding: var(--space-16) var(--space-16); width: min(720px, 92vw); max-height: 86vh; display: flex; flex-direction: column; gap: var(--space-12); }
  .sheet h3 { margin: 0; color: var(--paper); font: var(--text-title); }
  .end { justify-content: flex-end; }

  @media (max-width: 700px) {
    .panel { grid-template-columns: 1fr; height: auto; }
    .agent-list { max-height: 220px; border-right: none; border-bottom: 1px solid var(--separator); }
  }
</style>
