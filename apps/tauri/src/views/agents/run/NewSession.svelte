<script lang="ts">
  import Ico from "../../../components/ui/Ico.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import MicButton from "../../../components/MicButton.svelte";
  import AgentModelPicker from "./AgentModelPicker.svelte";
  import AntigravitySetup from "./AntigravitySetup.svelte";
  import ComposerContext from "./ComposerContext.svelte";
  import PromptTools from "./PromptTools.svelte";
  import RunsOnPicker from "./RunsOnPicker.svelte";
  import MachinePasswordField from "../../settings/MachinePasswordField.svelte";
  import { machinesApi, folderFor, isValidRemoteFolder, machineFolderLabel, rememberFolder, rememberedFolder, sharedMachines, type RemoteMachine } from "../../../lib/workspace/machines";
  import { prompts } from "../../../lib/workspace/prompts.svelte";
  import { compose, project as project_, type ContextRef } from "../../../lib/workspace/context-refs";
  // Een sessie starten (`NewSessionComposer` op de Mac): één vraag, één veld en een paar rustige keuzes eronder.
  // "Wat zullen we bouwen in nook?" — typ de opdracht, druk op Enter. Agent en account, model, modus, rechten, denkniveau, waar hij
  // werkt (deze map of een nieuwe worktree) en de branch waar hij van start staan al op je laatste keuzes in deze map. Titel,
  // branchnaam en de plek van de worktree volgen vanzelf.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agentApi, type AgentProfile } from "../../../lib/agents";
  import { pickableProfiles } from "../../../lib/account-options";
  import { agents } from "../../../lib/agents.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import {
    effortLevels, isActive, isScratch, projectName, workspaceApi, type ProjectOverride, type NewRunConfig, type PermissionPolicy, type ProjectInfo, type RunProvider,
  } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { catalog } from "../../../lib/workspace/models.svelte";
  import { continued as continuedList } from "../../../lib/workspace/composer-lists";
  import {
    MAX_MODELS, configs as comparisonConfigs, retrySelection, targets as comparisonTargets, toggling, type ComparisonTarget, type Outcome,
  } from "../../../lib/workspace/model-comparison";

  let { onstarted }: { onstarted: (id: string) => void } = $props();

  let config = $state<NewRunConfig>({
    title: "", task: "", provider: "claude", profileId: "claude", model: "", mode: "agent", permission: "acceptEdits",
    isolation: "worktree", projectPath: "", baseBranch: "", branchName: "", worktreeRoot: "", instructions: "", effort: null,
  });
  let profiles = $state<AgentProfile[]>([]);
  let project = $state<ProjectInfo | null>(null);
  let inspecting = $state(false);
  let starting = $state(false);
  let error = $state<string | null>(null);
  let allowShared = $state(false);
  // Files, folders and pictures you add, and the `@` / `#` references you typed (`ComposerContext`).
  let attached = $state<ContextRef[]>([]);
  let pictures = $state<string[]>([]);
  let mentions = $state<ContextRef[]>([]);
  let context = $state<ReturnType<typeof ComposerContext>>();
  let promptTools = $state<ReturnType<typeof PromptTools>>();
  /** Starting without a project (`ScratchProjects`): the folder is made when the session starts. */
  let noProject = $state(false);
  let showClone = $state(false);
  let cloneUrl = $state("");
  let cloning = $state(false);
  let menu = $state<"" | "project">("");
  let branchQuery = $state("");
  let textarea = $state<HTMLTextAreaElement>();
  let selectionRequest = 0;
  let prepared = false;
  /// The folder whose choices the composer shows.
  let folderApplied = "";
  /// Where the agent runs ("Runs on"): this computer (null) or a machine over SSH, with the folder typed for it there.
  let machines = $state<RemoteMachine[]>([]);
  let machine = $state<RemoteMachine | null>(null);
  let remoteFolder = $state("");
  /// For each machine that logs in with a password: whether Nook has it in this run.
  let unlocked = $state<Record<string, boolean>>({});
  const needsPassword = $derived(!!machine?.passwordLogin && !unlocked[machine.id]);
  /// "Automatic" under "Runs on": Nook picks this computer or a machine the project is shared with as it starts
  /// (`balance` in the core); kept for the next session.
  let automatic = $state((() => { try { return localStorage.getItem("nook.runsOn.automatic") === "1"; } catch { return false; } })());
  function setAutomatic(on: boolean) {
    automatic = on;
    try { localStorage.setItem("nook.runsOn.automatic", on ? "1" : "0"); } catch { /* a convenience only */ }
  }

  $effect(() => {
    const load = () => machinesApi.list().then(async (list) => {
      unlocked = await machinesApi.passwords().then((p) => Object.fromEntries(Object.entries(p).map(([id, s]) => [id, s.unlocked]))).catch(() => ({}));
      machines = list;
      // A machine removed in Settings while it was chosen: back to this computer.
      if (machine && !list.some((m) => m.id === machine!.id)) machine = null;
      else if (machine) machine = list.find((m) => m.id === machine!.id) ?? machine;
    }).catch(() => {});
    load();
    const un = machinesApi.onChanged(load);
    return () => { un.then((f) => f()); };
  });

  /// Picks where the agent runs; a machine starts in the folder you last used there.
  function pickMachine(m: RemoteMachine | null) {
    setAutomatic(false);
    // The project's folder there when it is shared with this machine, else the folder used there last.
    const shared = m && !machine && !noProject ? folderFor(m, config.projectPath) : null;
    machine = m;
    error = null;
    if (m) remoteFolder = shared || rememberedFolder(m.id) || remoteFolder || "~";
    requestAnimationFrame(() => textarea?.focus());
  }

  const settings = $derived(workspace.settings);
  const runnable = $derived(workspace.providers.filter((p) => p.supported));
  const enabledProfiles = $derived(pickableProfiles(profiles));
  const hasEnabledAccount = (p: RunProvider) => {
    const all = profiles.filter((x) => x.kind === p);
    return all.length === 0 || enabledProfiles.some((x) => x.kind === p);
  };
  const connected = $derived(runnable.filter((p) => p.executable && hasEnabledAccount(p.provider)));
  const provider = $derived(workspace.provider(config.provider));
  const policies = $derived<PermissionPolicy[]>(provider?.capabilities.policies ?? ["acceptEdits"]);
  const profilesFor = (p: RunProvider) => enabledProfiles.filter((x) => x.kind === p);

  function cleanProjectPath(raw: string): string {
    const trimmed = raw.trim();
    return trimmed.length > 1 ? trimmed.replace(/[\\/]+$/, "") : trimmed;
  }

  // What each project sets for itself (Settings › Projects, `ProjectSettings`): its name in the lists, whether it is
  // archived (no longer offered, unless it is the one chosen now), and its values for a new session.
  const overrides = $derived((settings as unknown as { projectOverrides?: Record<string, ProjectOverride> } | null)?.projectOverrides ?? {});
  const archived = (path: string) => !!overrides[cleanProjectPath(path)]?.archived && cleanProjectPath(path) !== cleanProjectPath(config.projectPath);
  const displayName = (path: string) => overrides[cleanProjectPath(path)]?.name?.trim() || projectName(path);

  const favorites = $derived.by(() => {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const raw of settings?.favoriteProjects ?? []) {
      const path = cleanProjectPath(raw);
      if (!path || seen.has(path) || archived(path)) continue;
      seen.add(path);
      out.push(path);
    }
    return out;
  });

  const recent = $derived.by(() => {
    const seen = new Set<string>(favorites);
    const limit = Math.max(3, 10 - favorites.length);
    const out: string[] = [];
    for (const raw of [config.projectPath, settings?.lastProject ?? "", ...(settings?.recentProjects ?? []), ...(agents.history?.sessions ?? []).map((s) => s.cwd)]) {
      const path = cleanProjectPath(raw);
      if (!path || seen.has(path) || isScratch(path) || archived(path)) continue;
      seen.add(path);
      out.push(path);
      if (out.length === limit) break;
    }
    return out;
  });

  function toggleFavorite(path: string) {
    const clean = cleanProjectPath(path);
    if (!clean) return;
    workspaceApi.toggleFavoriteProject(clean).catch(() => {});
  }

  // Comparing models (`ModelComparison`): the same prompt to more models, each in a worktree of its own.
  let extras = $state<ComparisonTarget[]>([]);
  const primaryTarget = $derived<ComparisonTarget>({ provider: config.provider, profileId: config.profileId, model: config.model });
  // Not on another machine: each model would need a worktree there, which this app cannot make yet (AG-132).
  const comparing = $derived(extras.length > 0 && !noProject && !machine);
  function targetName(t: ComparisonTarget): string {
    const agent = workspace.provider(t.provider)?.name ?? t.provider;
    const model = t.model ? catalog.find(t.provider, t.model)?.name ?? t.model : tr("standaard", "default");
    return `${agent} ${model}`;
  }
  /** Every agent's current models, under the account it would run with. */
  const compareChoices = $derived<ComparisonTarget[]>(runnable.filter((p) => p.executable).flatMap((p) => {
    const own = profiles.filter((x) => x.kind === p.provider);
    const profileId = p.provider === config.provider ? config.profileId : (own.find((x) => x.preferred) ?? own[0])?.id ?? p.provider;
    const models = (catalog.byAgent[p.provider] ?? []).filter((m) => m.current);
    return models.length ? models.map((m) => ({ provider: p.provider, profileId, model: m.id })) : [{ provider: p.provider, profileId, model: "" }];
  }));
  const isExtra = (t: ComparisonTarget) => extras.some((e) => e.provider === t.provider && e.profileId === t.profileId && e.model === t.model);

  const worktreeAllowed = $derived(!!project && project.verdict === "ok" && !!project.repoRoot && project.hasCommits && !!workspace.overview?.gitAvailable);
  const worktreeBlocked = $derived(
    !workspace.overview?.gitAvailable ? tr("Git is niet gevonden. Installeer Git en start Nook opnieuw.", "Git wasn't found. Install Git and restart Nook.")
      : !project ? tr("Kies een project of map", "Choose a project or folder")
        : !project.repoRoot ? tr("Een worktree kan alleen in een Git-repository.", "A worktree only works in a Git repository.")
          : !project.hasCommits ? tr("Een worktree kan pas na de eerste commit.", "A worktree needs at least one commit.") : "",
  );
  const sharing = $derived(
    project && project.verdict === "ok"
      ? workspace.runs.filter((r) => isActive(r.status) && (r.workingDirectory === (project!.repoRoot ?? project!.path) || r.workingDirectory === project!.path))
      : [],
  );
  const blockingReason = $derived.by((): string | null => {
    if (!config.task.trim() && !attached.length && !pictures.length) return tr("Schrijf eerst een opdracht.", "Write a task first.");
    if (machine) {
      // On another machine: the agent must be there, not here; ssh and the folder are checked as it starts.
      if (needsPassword) return tr("Typ eerst het wachtwoord van {machine}.", "Type the password for {machine} first.", { machine: machine.name });
      if (!isValidRemoteFolder(remoteFolder)) return tr("Typ de map op {machine}: vanaf / of ~/.", "Type the folder on {machine}: from / or ~/.", { machine: machine.name });
      if (!policies.includes(config.permission)) return tr("Deze agent ondersteunt die rechten niet.", "This agent doesn't support that permission.");
      if (!provider?.supported) return tr("Nook kan {agent} op dit platform niet zelf aansturen; dat kan op een computer.", "Nook can't drive {agent} itself on this platform; it can on a computer.", { agent: provider?.name ?? config.provider });
      return null;
    }
    if (noProject) {
      // A folder of its own is made when it starts: only the agent has to be able to run.
      if (!policies.includes(config.permission)) return tr("Deze agent ondersteunt die rechten niet.", "This agent doesn't support that permission.");
      if (!provider?.supported) return tr("Nook kan {agent} op dit platform niet zelf aansturen; dat kan op een computer.", "Nook can't drive {agent} itself on this platform; it can on a computer.", { agent: provider?.name ?? config.provider });
      if (!provider?.executable) return tr("{agent} staat niet op deze computer.", "{agent} isn't installed on this computer.", { agent: provider?.name ?? config.provider });
      return null;
    }
    if (!config.projectPath) return tr("Kies een map.", "Choose a folder.");
    if (!policies.includes(config.permission)) return tr("Deze agent ondersteunt die rechten niet.", "This agent doesn't support that permission.");
    if (config.isolation === "worktree" && !config.baseBranch) return tr("Kies een basis-branch.", "Choose a base branch.");
    if (project?.verdict !== "ok") return project?.verdictMessage || tr("Kies een map.", "Choose a folder.");
    if (!provider?.supported) return tr("Nook kan {agent} op dit platform niet zelf aansturen; dat kan op een computer.", "Nook can't drive {agent} itself on this platform; it can on a computer.", { agent: provider?.name ?? config.provider });
    if (!provider?.executable) return tr("{agent} staat niet op deze computer.", "{agent} isn't installed on this computer.", { agent: provider?.name ?? config.provider });
    if (config.isolation === "folder" && !allowShared && sharing.length) return tr("Kies een worktree of bevestig de gedeelde map.", "Choose a worktree or confirm the shared folder.");
    return null;
  });

  $effect(() => {
    if (prepared || !settings || !workspace.providers.length) return;
    prepared = true;
    prepare();
  });

  async function prepare() {
    profiles = await agentApi.profiles().catch(() => []);
    const list = connected.map((p) => p.provider);
    const p = list.includes(settings!.defaultProvider) ? settings!.defaultProvider : (list[0] ?? settings!.defaultProvider);
    choose(p, null);
    config.model = rememberedModel(p);
    config.effort = rememberedEffort(p);
    config.mode = settings!.defaultMode;
    config.isolation = settings!.defaultIsolation;
    config.worktreeRoot = settings!.worktreeRoot;
    requestAnimationFrame(() => textarea?.focus());
    const candidates = settings!.lastProject ? [settings!.lastProject] : [...favorites, ...recent];
    for (const path of candidates) {
      const result = await select(path);
      if (result === "stale") return;
      if (result === "ok") break;
    }
  }

  function choose(p: RunProvider, account: string | null) {
    if (config.provider !== p) {
      config.provider = p;
      config.model = rememberedModel(p);
      config.effort = rememberedEffort(p);
    }
    const caps = workspace.provider(p)?.capabilities.policies ?? ["acceptEdits"];
    if (!caps.includes(config.permission)) {
      const preferred = settings?.defaultPermission ?? "acceptEdits";
      config.permission = caps.includes(preferred) ? preferred : "acceptEdits";
    }
    const own = profilesFor(p);
    // The account you last chose for this agent in this folder or else anywhere, while it is still there, else its
    // preferred or first one.
    const remembered = [folderChoices(config.projectPath)?.agents[p]?.profileId, settings?.defaultProfiles?.[p]].find((saved) => saved && own.some((x) => x.id === saved));
    config.profileId = account ?? remembered ?? (own.find((x) => x.preferred) ?? own[0])?.id ?? p;
  }

  /// What you last chose in this folder, if anything.
  function folderChoices(path: string) {
    return settings?.folderChoices?.[cleanProjectPath(path)];
  }

  /// The model last chosen for this agent in this folder, else anywhere.
  function rememberedModel(p: RunProvider): string {
    return folderChoices(config.projectPath)?.agents[p]?.model ?? settings?.defaultModels[p] ?? "";
  }

  /// The effort last chosen for this agent in this folder, else anywhere, while the agent still offers it.
  function rememberedEffort(p: RunProvider): string | null {
    const chosen = folderChoices(config.projectPath)?.agents[p];
    const saved = chosen ? chosen.effort : settings?.defaultEfforts?.[p];
    return saved && effortLevels(p).includes(saved) ? saved : null;
  }

  /// Sets the choices to what a new session in the current folder starts with. Your agent for it, unless that is not
  /// connected: then your default one, or else the first that is.
  function applyFolderChoices() {
    if (!settings) return;
    const saved = folderChoices(config.projectPath);
    const list = connected.map((p) => p.provider);
    const p = [saved?.provider, settings.defaultProvider].find((x) => x && list.includes(x)) ?? list[0] ?? settings.defaultProvider;
    config.provider = p;
    config.mode = saved?.mode ?? settings.defaultMode;
    config.permission = saved?.permission ?? settings.defaultPermission;
    config.isolation = saved?.isolation ?? settings.defaultIsolation;
    config.model = rememberedModel(p);
    config.effort = rememberedEffort(p);
    choose(p, null);
  }

  /// Keeps what you just chose for the next new session in this folder, and as the start for folders without choices
  /// of their own.
  function remember() {
    if (!settings) return;
    const p = config.provider;
    const efforts = { ...(settings.defaultEfforts ?? {}) };
    if (config.effort) efforts[p] = config.effort;
    else delete efforts[p];
    const folder = cleanProjectPath(config.projectPath);
    const folders = { ...(settings.folderChoices ?? {}) };
    if (folder) {
      folders[folder] = {
        provider: p,
        mode: config.mode,
        permission: config.permission,
        isolation: config.isolation,
        agents: { ...(folders[folder]?.agents ?? {}), [p]: { profileId: config.profileId, model: config.model, effort: config.effort } },
      };
    }
    workspaceApi
      .saveSettings({
        ...$state.snapshot(settings),
        defaultProvider: p,
        defaultModels: { ...settings.defaultModels, [p]: config.model },
        defaultProfiles: { ...(settings.defaultProfiles ?? {}), [p]: config.profileId },
        defaultEfforts: efforts,
        defaultMode: config.mode,
        defaultPermission: config.permission,
        defaultIsolation: config.isolation,
        folderChoices: folders,
      })
      .catch(() => {});
  }

  /// "Or start without a project": no folder to pick; the session gets an empty one of its own when it starts.
  function startWithoutProject() {
    selectionRequest++;
    menu = "";
    noProject = true;
    project = null;
    inspecting = false;
    error = null;
    config.projectPath = "";
    config.isolation = "folder";
    config.baseBranch = "";
  }

  async function select(path: string): Promise<"ok" | "failed" | "stale"> {
    noProject = false;
    const request = ++selectionRequest;
    menu = "";
    config.projectPath = path;
    inspecting = true;
    error = null;
    try {
      const info = await workspaceApi.inspect(path);
      if (request !== selectionRequest) return "stale";
      project = info;
      config.projectPath = info.path;
      const folder = cleanProjectPath(info.path);
      if (folder !== folderApplied) {
        folderApplied = folder;
        applyFolderChoices();
        // The project's own values win over what you last chose there (`ProjectSettings.composerDefaults`).
        const own = await workspaceApi.projectSettings(info.path).catch(() => null);
        if (request !== selectionRequest) return "stale";
        // A backend that answers without defaults (an older one, or a failure) leaves your last choices as they are.
        const d = own?.defaults;
        if (d && Array.isArray(d.own)) {
          if (d.own.includes("provider") && connected.some((p) => p.provider === d.provider)) choose(d.provider, null);
          if (d.own.includes("mode")) config.mode = d.mode;
          if (d.own.includes("permission")) config.permission = d.permission;
          if (d.own.includes("isolation")) config.isolation = d.isolation;
        }
      }
      const canWorktree = !!info.repoRoot && info.hasCommits && !!workspace.overview?.gitAvailable;
      if (!canWorktree) config.isolation = "folder";
      else if (config.isolation === "folder" && (folderChoices(folder)?.isolation ?? settings?.defaultIsolation) === "worktree") config.isolation = "worktree";
      config.baseBranch = info.defaultBase && info.branches.includes(info.defaultBase) ? info.defaultBase : (info.currentBranch ?? info.branches[0] ?? "");
      return info.verdict === "ok" ? "ok" : "failed";
    } catch (e) {
      if (request !== selectionRequest) return "stale";
      error = String(e);
      return "failed";
    } finally {
      if (request === selectionRequest) inspecting = false;
    }
  }

  async function chooseFolder() {
    menu = "";
    try {
      const picked = await openDialog({ directory: true, multiple: false, title: tr("In welke map werkt de agent?", "Which folder does the agent work in?"), defaultPath: project?.path });
      if (typeof picked === "string") select(picked);
    } catch (e) {
      error = String(e);
    }
  }

  /// "+ Add a file or folder" (`ComposerPlusMenu`): its path goes into the task, where the agent reads it.
  async function attachFile() {
    try {
      const picked = await openDialog({ multiple: true, defaultPath: project?.path, title: tr("Bestand of map toevoegen", "Add a file or folder") });
      for (const path of Array.isArray(picked) ? picked : picked ? [picked] : []) context?.addPath(path);
      textarea?.focus();
    } catch (e) {
      error = String(e);
    }
  }

  async function clone() {
    if (cloning || !cloneUrl.trim()) return;
    cloning = true;
    error = null;
    try {
      const path = await workspaceApi.clone(cloneUrl.trim(), project?.repoRoot ?? project?.path ?? null);
      showClone = false;
      cloneUrl = "";
      select(path);
    } catch (e) {
      error = String(e);
    }
    cloning = false;
  }

  /** One session per chosen model, each in a worktree; what failed stays chosen with the prompt, to try again. */
  async function startComparison(task: string, background: boolean) {
    const list = comparisonTargets(primaryTarget, extras);
    const titleFrom = (text: string) => text.split("\n").map((l) => l.trim()).filter(Boolean).join(" ").slice(0, 60);
    const all = comparisonConfigs({ ...config, task }, list, targetName, (p) => workspace.provider(p)?.capabilities.policies ?? [], () => titleFrom(config.task));
    const outcome: Outcome = { started: [], failed: [] };
    for (let i = 0; i < all.length; i++) {
      try {
        outcome.started.push({ target: list[i], id: await workspaceApi.start(all[i], false) });
      } catch (e) {
        outcome.failed.push({ target: list[i], message: String(e) });
      }
    }
    await workspace.refresh();
    const retry = retrySelection(outcome);
    if (retry) {
      config.provider = retry.primary.provider;
      config.profileId = retry.primary.profileId;
      config.model = retry.primary.model;
      extras = retry.extras;
      error = outcome.failed.map((f) => `${targetName(f.target)}: ${f.message}`).join("\n");
    } else {
      extras = [];
      attached = [];
      pictures = [];
      mentions = [];
      try { localStorage.removeItem(draftKey(config.projectPath, null)); } catch { /* nothing kept */ }
      config.task = "";
    }
    if (outcome.started.length) {
      toast.success(tr("{n} sessies gestart", "{n} sessions started", { n: outcome.started.length }));
      if (!background && !retry) onstarted(outcome.started[0].id);
    }
  }

  /// Whether "Automatic" decides where this session starts: a project on this computer, not "No project" and not while
  /// comparing models, which needs worktrees here.
  const startsAutomatically = $derived(automatic && !machine && !noProject && !!config.projectPath && !comparing && !isScratch(config.projectPath));
  const autoShared = $derived(startsAutomatically ? sharedMachines(machines, config.projectPath) : []);

  async function start(background = false) {
    if (starting || blockingReason) return;
    starting = true;
    error = null;
    if (startsAutomatically && autoShared.length) {
      // "Automatic": this computer, or the shared machine with the most room for its level.
      try {
        const place = await machinesApi.pick(config.projectPath, config.provider, !!provider?.executable);
        if (place) {
          const task = project_(compose(config.task, attached, mentions), pictures);
          const id = await workspaceApi.start({ ...config, task, projectPath: place.folder, isolation: "folder", baseBranch: "", branchName: "", machineId: place.machineId }, false);
          toast.success(tr("Gestart op {machine}", "Started on {machine}", { machine: place.name }));
          attached = [];
          pictures = [];
          mentions = [];
          try { localStorage.removeItem(draftKey(config.projectPath, null)); } catch { /* nothing kept */ }
          config.task = "";
          await workspace.refresh();
          if (!background) onstarted(id);
          starting = false;
          return;
        }
      } catch (e) {
        error = String(e);
        starting = false;
        return;
      }
    }
    if (comparing) {
      try {
        await startComparison(project_(compose(config.task, attached, mentions), pictures), background);
      } catch (e) {
        error = String(e);
      }
      starting = false;
      return;
    }
    try {
      const task = project_(compose(config.task, attached, mentions), pictures);
      const id = machine
        ? await workspaceApi.start({ ...config, task, projectPath: remoteFolder.trim(), isolation: "folder", baseBranch: "", branchName: "", machineId: machine.id }, false)
        : await workspaceApi.start({ ...config, task, projectPath: noProject ? "" : config.projectPath, branchName: "", machineId: "" }, allowShared);
      if (machine) {
        rememberFolder(machine.id, remoteFolder);
        // The project on this computer is now shared with the machine: "Automatic" may start it there.
        if (!noProject && config.projectPath && !isScratch(config.projectPath)) machinesApi.shareProject(machine.id, config.projectPath, remoteFolder.trim()).catch(() => {});
      }
      attached = [];
      pictures = [];
      mentions = [];
      try { localStorage.removeItem(draftKey(config.projectPath, machine)); } catch { /* nothing kept */ }
      config.task = "";
      await workspace.refresh();
      if (background) toast.success(tr("Sessie gestart", "Session started"));
      else onstarted(id);
    } catch (e) {
      error = String(e);
    }
    starting = false;
  }

  function sortedBranches(list: string[]): string[] {
    const base = project?.defaultBase;
    const q = branchQuery.trim().toLowerCase();
    return [...list].filter((b) => !q || b.toLowerCase().includes(q)).sort((a, b) => (a === base ? -1 : b === base ? 1 : a.localeCompare(b, undefined, { numeric: true })));
  }

  function keydown(e: KeyboardEvent) {
    if (context?.key(e)) return;
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      // Ctrl+Alt+Return (`composer.startInBackground`): it starts, and this screen stays for the next one.
      start(e.ctrlKey && e.altKey);
    }
  }

  // A draft per folder (`ComposerDraftStore` on the Mac): what you typed for a project waits there when you switch to
  // another one and back, and survives closing the window; starting the session clears it.
  const draftKey = (folder: string, on: RemoteMachine | null) =>
    on ? `nook.newSession.draft:machine:${on.id}` : `nook.newSession.draft:${noProject ? "" : cleanProjectPath(folder)}`;
  let draftFolder = "";
  $effect(() => {
    const key = draftKey(config.projectPath, machine);
    const text = config.task;
    if (key !== draftFolder) {
      // Another folder: its own draft comes back, unless you were typing one already.
      draftFolder = key;
      if (!text.trim()) {
        try { config.task = localStorage.getItem(key) ?? ""; } catch { /* no storage: no draft */ }
      }
      return;
    }
    try {
      if (text.trim()) localStorage.setItem(key, text);
      else localStorage.removeItem(key);
    } catch { /* no storage: the draft lasts while the screen is open */ }
  });

  // "+ Add project" in the session list picks a folder and opens this screen on it.
  $effect(() => {
    const on = (e: Event) => { const path = (e as CustomEvent<string>).detail; if (path) select(path); };
    window.addEventListener("nook-agents-project", on);
    return () => window.removeEventListener("nook-agents-project", on);
  });

  const stop = (e: Event) => e.stopPropagation();
  const startLabel = $derived(starting ? (config.isolation === "worktree" && !machine ? tr("Worktree maken en agent starten…", "Creating worktree and starting agent…") : tr("Agent starten…", "Starting agent…")) : tr("Start sessie", "Start session"));

  // Markdown lists keep going (`ComposerLists`): a new line after "- item" or "7." starts the next item; one after an
  // empty item ends the list.
  function listInput(e: Event) {
    const field = e.currentTarget as HTMLTextAreaElement;
    if ((e as InputEvent).inputType !== "insertLineBreak" && !((e as InputEvent).inputType === "insertText" && (e as InputEvent).data === "\n")) return;
    const next = continuedList(field.value, field.selectionStart ?? field.value.length);
    if (!next) return;
    config.task = next.text;
    field.value = next.text;
    field.setSelectionRange(next.caret, next.caret);
  }
</script>

<svelte:window onclick={() => (menu = "")} />

<div class="new">
  <div class="spacer-v"></div>
  <!-- The question and the way out of a project under it (`NewSessionComposer.heading`): "or start without a project";
       without one, the question drops the folder and "No project ⌄" opens the projects to pick one again. -->
  <div class="heading-wrap">
    {#if machine}
      <!-- On another machine (`NewSessionComposer.remoteRow`): the folder there is typed, there is no folder panel for it. -->
      <h2 class="heading">{tr("Wat zullen we bouwen in", "What should we build in")} <span class="project static">{machineFolderLabel(machine, remoteFolder)}</span><span class="qmark">?</span></h2>
      <label class="remote">
        <Ico name="server" size={14} />
        <span class="remote-label">{tr("Map op {machine}:", "Folder on {machine}:", { machine: machine.name })}</span>
        <input bind:value={remoteFolder} placeholder="~/code/app" spellcheck="false" autocomplete="off" aria-label={tr("Map op {machine}:", "Folder on {machine}:", { machine: machine.name })} />
        <button class="ghost" title={tr("Terug naar deze computer", "Back to this computer")} aria-label={tr("Terug naar deze computer", "Back to this computer")} onclick={() => pickMachine(null)}>✕</button>
      </label>
      {#if needsPassword}
        <!-- A machine that logs in with a password asks for it once, before its first session in this run of Nook. -->
        <div class="remote"><MachinePasswordField {machine} onunlocked={() => (unlocked = { ...unlocked, [machine!.id]: true })} /></div>
      {/if}
    {:else if noProject}
      <h2 class="heading">{tr("Waar zullen we aan werken?", "What should we work on?")}</h2>
      <span class="pop">
        <button class="sub on" onclick={(e) => { stop(e); menu = menu === "project" ? "" : "project"; }}>{tr("Geen project", "No project")} <Ico name="chevron-down" size={10} stroke={2.5} /></button>
      {#if menu === "project"}
          <div class="menu" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            {#if favorites.length}
              <div class="mhead">{tr("Favorieten", "Favorites")}</div>
              {#each favorites as path (path)}
                <div class="mrow" class:chosen={cleanProjectPath(project?.path ?? "") === path}>
                  <button class="mitem" onclick={() => select(path)}><span>{displayName(path)}</span><span class="faint small">{path}</span></button>
                  <button class="star starred" title={tr("Verwijder uit favorieten", "Remove from favorites")} aria-label={tr("Verwijder uit favorieten", "Remove from favorites")} onclick={() => toggleFavorite(path)}>★</button>
                </div>
              {/each}
            {/if}
            {#if recent.length}
              <div class="mhead">{tr("Recent", "Recent")}</div>
              {#each recent as path (path)}
                <div class="mrow" class:chosen={cleanProjectPath(project?.path ?? "") === path}>
                  <button class="mitem" onclick={() => select(path)}><span>{displayName(path)}</span><span class="faint small">{path}</span></button>
                  <button class="star" title={tr("Voeg toe aan favorieten", "Add to favorites")} aria-label={tr("Voeg toe aan favorieten", "Add to favorites")} onclick={() => toggleFavorite(path)}>☆</button>
                </div>
              {/each}
            {/if}
            {#if favorites.length || recent.length}
              <hr />
            {/if}
            <button onclick={chooseFolder}>{tr("Kies map…", "Choose folder…")}</button>
            <button onclick={() => { menu = ""; showClone = true; }}>{tr("Kloon een repository…", "Clone a repository…")}</button>
          </div>
        {/if}
      </span>
    {:else}
      <h2 class="heading">
        {tr("Wat zullen we bouwen in", "What should we build in")}
        <span class="pop">
          <button class="project" onclick={(e) => { stop(e); menu = menu === "project" ? "" : "project"; }} title={project?.path ?? tr("Kies een project of map", "Choose a project or folder")}>
            {project ? displayName(project.path) : (config.projectPath ? displayName(config.projectPath) : tr("welke map", "which folder"))}
          </button>
      {#if menu === "project"}
            <div class="menu" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
              {#if favorites.length}
                <div class="mhead">{tr("Favorieten", "Favorites")}</div>
                {#each favorites as path (path)}
                  <div class="mrow" class:chosen={cleanProjectPath(project?.path ?? "") === path}>
                    <button class="mitem" onclick={() => select(path)}><span>{displayName(path)}</span><span class="faint small">{path}</span></button>
                    <button class="star starred" title={tr("Verwijder uit favorieten", "Remove from favorites")} aria-label={tr("Verwijder uit favorieten", "Remove from favorites")} onclick={() => toggleFavorite(path)}>★</button>
                  </div>
                {/each}
              {/if}
              {#if recent.length}
                <div class="mhead">{tr("Recent", "Recent")}</div>
                {#each recent as path (path)}
                  <div class="mrow" class:chosen={cleanProjectPath(project?.path ?? "") === path}>
                    <button class="mitem" onclick={() => select(path)}><span>{displayName(path)}</span><span class="faint small">{path}</span></button>
                    <button class="star" title={tr("Voeg toe aan favorieten", "Add to favorites")} aria-label={tr("Voeg toe aan favorieten", "Add to favorites")} onclick={() => toggleFavorite(path)}>☆</button>
                  </div>
                {/each}
              {/if}
              {#if favorites.length || recent.length}
                <hr />
              {/if}
              <button onclick={chooseFolder}>{tr("Kies map…", "Choose folder…")}</button>
              <button onclick={() => { menu = ""; showClone = true; }}>{tr("Kloon een repository…", "Clone a repository…")}</button>
            </div>
          {/if}
        </span><span class="qmark">?</span>
        {#if inspecting}<span class="faint small">{tr("Map bekijken…", "Checking folder…")}</span>{/if}
      </h2>
      <button class="sub" title={tr("Een lege map van zichzelf in ~/.nook/scratch", "An empty folder of its own in ~/.nook/scratch")} onclick={startWithoutProject}>{tr("of begin zonder project", "or start without a project")}</button>
    {/if}
  </div>

  {#if showClone}
    <div class="clone">
      <input bind:value={cloneUrl} placeholder={tr("https://github.com/eigenaar/repo.git", "https://github.com/owner/repo.git")} onkeydown={(e) => e.key === "Enter" && clone()} />
      <button disabled={cloning || !cloneUrl.trim()} onclick={clone}>{cloning ? tr("Klonen…", "Cloning…") : tr("Kloon", "Clone")}</button>
      <button class="ghost" onclick={() => (showClone = false)}>✕</button>
    </div>
  {/if}

  <!-- The Mac's composer (`SessionComposer`): the task on top; under it "+", the one agent pill (its mode, access and
       effort live in the picker's footer, as `ModelPickerOptions`), the microphone and the round send button. -->
  <PromptTools bind:this={promptTools} bind:draft={config.task} {textarea} />
  <div class="box">
    <ComposerContext bind:this={context} {textarea} bind:draft={config.task} root={noProject || machine ? null : (project?.path ?? null)} provider={config.provider} bind:attached bind:pictures bind:mentions />
    <textarea bind:this={textarea} bind:value={config.task} rows="2" placeholder={tr("Beschrijf wat de agent moet doen. Enter start de sessie.", "Describe what the agent should do. Return starts the session.")} onkeydown={keydown} oninput={listInput}></textarea>
    <div class="bar">
      <Dropdown width={260} label={tr("Meer opties", "More options")}>
        {#snippet trigger({ toggle, open })}
          <button class="plus" class:lit={open} onclick={toggle} title={tr("Meer opties", "More options")} aria-label={tr("Meer opties", "More options")} aria-expanded={open}><Ico name="plus" size={14} stroke={2.4} /></button>
        {/snippet}
        {#snippet children({ close })}
          <DropdownRow symbol="paperclip" title={tr("Bestand of map toevoegen", "Add a file or folder")} onclick={() => { close(); attachFile(); }} />
          <!-- The prompt library (`PromptLibrary`): keep what you typed, or use a saved prompt. -->
          <DropdownRow symbol="bookmark" title={tr("Bewaar als prompt…", "Save as prompt…")} disabledReason={config.task.trim() ? undefined : tr("Typ eerst wat je wilt bewaren.", "Type what you want to keep first.")} onclick={() => { close(); promptTools?.openSave(); }} />
          {#if prompts.list.length}
            <div class="dd-header">{tr("Prompts", "Prompts")}</div>
            {#each prompts.list.slice(0, 8) as p (p.id)}
              <DropdownRow symbol="message-square-text" title={p.title} trailing={p.trigger ? `/${p.trigger}` : undefined} onclick={() => { close(); promptTools?.use(p); }} />
            {/each}
          {/if}
        {/snippet}
      </Dropdown>
      {#if !connected.length}
        <span class="faint small hint" title={tr("Nog geen agent gekoppeld. Koppel er een bij Instellingen › Agents.", "No agent linked yet. Link one in Settings › Agents.")}>{tr("Nog geen agent gekoppeld. Koppel er een bij Instellingen › Agents.", "No agent linked yet. Link one in Settings › Agents.")}</span>
      {/if}
      <AgentModelPicker providers={runnable} {profiles} provider={config.provider} profileId={config.profileId} model={config.model}
        mode={config.mode} permission={config.permission} effort={config.effort}
        title={tr("Deze sessie houdt dit account, ook als je later het standaardaccount wisselt.", "This session keeps this account, even if you switch the default account later.")}
        onchoose={(p, account, model) => { choose(p, account); config.model = model; remember(); }}
        onmode={(m) => { config.mode = m; remember(); }}
        onpermission={(p) => { config.permission = p; remember(); }}
        oneffort={(l) => { config.effort = l; remember(); }} />
      {#if !noProject && !machine}
        <!-- "Compare": the same prompt to more models at once, each in a worktree of its own (`ModelComparison`). -->
        <Dropdown width={280} label={tr("Vergelijk modellen", "Compare models")}>
          {#snippet trigger({ toggle, open })}
            <button class="pill" class:lit={open || comparing} onclick={toggle} aria-expanded={open}
              title={worktreeAllowed ? tr("Stuur dezelfde prompt naar meer modellen, elk in een eigen worktree", "Send the same prompt to more models, each in a worktree of its own") : worktreeBlocked}>
              <Ico name="columns-2" size={14} />{#if comparing}<span>{tr("{n} modellen", "{n} models", { n: extras.length + 1 })}</span>{/if}
            </button>
          {/snippet}
          {#snippet children()}
            <div class="dd-header">{tr("Ook naar (max. {n} samen)", "Also send to (at most {n} together)", { n: MAX_MODELS })}</div>
            {#each compareChoices as t (`${t.provider}/${t.profileId}/${t.model}`)}
              {@const isPrimary = t.provider === primaryTarget.provider && t.model === primaryTarget.model}
              <DropdownRow brand={workspace.provider(t.provider)?.name} title={targetName(t)} chosen={isPrimary || isExtra(t)}
                disabledReason={!worktreeAllowed ? worktreeBlocked : isPrimary ? tr("Dit model is al gekozen.", "This model is already chosen.") : !isExtra(t) && extras.length + 1 >= MAX_MODELS ? tr("Hooguit {n} modellen tegelijk.", "At most {n} models at once.", { n: MAX_MODELS }) : undefined}
                onclick={() => (extras = toggling(t, extras, primaryTarget))} />
            {/each}
            {#if extras.length}
              <DropdownRow symbol="x" title={tr("Niet vergelijken", "Don't compare")} onclick={() => (extras = [])} />
            {/if}
          {/snippet}
        </Dropdown>
      {/if}
      {#if config.mode === "plan"}
        <!-- Plan mode stays in sight as its own pill (`ModeToggle`), a click back to Agent. -->
        <span class="divider"></span>
        <button class="pill" title={tr("Alleen lezen en een plan maken; er wordt niets aangepast.", "Only read and make a plan; nothing is changed.")} onclick={() => { config.mode = "agent"; remember(); }}><Ico name="list-checks" size={15} /><span>{tr("Plan", "Plan")}</span></button>
      {/if}
      <span class="spacer"></span>
      <MicButton size={15} />
      <!-- The round send button of every composer on the Mac; what it does is in its name. -->
      <button class="send" disabled={!!blockingReason || starting} title={blockingReason ?? startLabel} aria-label={startLabel} onclick={() => start()}>
        {#if starting}<span class="spin"><Ico name="refresh-cw" size={14} /></span>{:else}<Ico name="arrow-up" size={14} stroke={2.6} />{/if}
      </button>
    </div>
  </div>

  <!-- Under the box, tucked against it (`ComposerTray`): where the agent works and from which branch. -->
  <div class="below">
    <RunsOnPicker {machines} chosen={machine} {automatic} onpick={pickMachine} onautomatic={() => { pickMachine(null); setAutomatic(true); }} />
    {#if machine}
      <span class="pill static"><Ico name="folder" size={15} /><span>{tr("Huidige map", "Current folder")}</span></span>
    {:else if !noProject && (!project || project.repoRoot)}
      <Dropdown width={300} below label={tr("Waar de agent werkt", "Where the agent works")}>
        {#snippet trigger({ toggle, open })}
          <button class="pill" onclick={toggle} aria-expanded={open} title={worktreeAllowed ? "" : worktreeBlocked}>
            <Ico name={config.isolation === "worktree" ? "layers" : "folder"} size={15} /><span>{config.isolation === "worktree" ? tr("Nieuwe worktree", "New worktree") : tr("Huidige map", "Current folder")}</span><Ico name="chevron-down" size={10} stroke={2.5} />
          </button>
        {/snippet}
        {#snippet children({ close })}
          <div class="dd-header">{tr("Waar de agent werkt", "Where the agent works")}</div>
          <DropdownRow symbol="folder" title={tr("Huidige map", "Current folder")} detail={tr("In de map zelf, op de branch die er nu staat.", "In the folder itself, on the branch that's checked out now.")}
            chosen={config.isolation === "folder"} onclick={() => { close(); config.isolation = "folder"; remember(); }} />
          <DropdownRow symbol="layers" title={tr("Nieuwe worktree", "New worktree")} detail={tr("De agent krijgt een eigen map en branch. Je eigen checkout en branch blijven precies zoals ze zijn.", "The agent gets its own folder and branch. Your own checkout and branch stay exactly as they are.")}
            chosen={config.isolation === "worktree"} disabledReason={worktreeAllowed ? undefined : worktreeBlocked} onclick={() => { close(); config.isolation = "worktree"; remember(); }} />
        {/snippet}
      </Dropdown>
    {/if}
    <span class="spacer"></span>
    {#if machine}
      <span class="pill static faint-pill">{tr("via SSH · {host}", "via SSH · {host}", { host: machine.host })}</span>
    {:else if noProject}
      <!-- A folder of its own: no branch to show. -->
    {:else if config.isolation === "worktree" && project?.branches.length}
      <Dropdown width={280} below align="right" label={tr("Basis-branch", "Base branch")} onopen={() => (branchQuery = "")}>
        {#snippet trigger({ toggle, open })}
          <button class="pill branch" onclick={toggle} aria-expanded={open}><Ico name="git-branch" size={15} /><span>{tr("Vanaf {branch}", "From {branch}", { branch: config.baseBranch })}</span><Ico name="chevron-down" size={10} stroke={2.5} /></button>
        {/snippet}
        {#snippet children({ close })}
          <label class="branch-search"><Ico name="search" size={14} /><input bind:value={branchQuery} placeholder={tr("Zoek branches…", "Search branches…")} aria-label={tr("Zoek branches…", "Search branches…")} /></label>
          <div class="scrolllist">
            {#each sortedBranches(project?.branches ?? []) as b (b)}
              <DropdownRow symbol="git-branch" title={b} chosen={config.baseBranch === b} onclick={() => { close(); config.baseBranch = b; }} />
            {:else}
              <p class="none">{tr("Geen branches gevonden", "No branches found")}</p>
            {/each}
          </div>
        {/snippet}
      </Dropdown>
    {:else if project?.currentBranch}
      <span class="pill static branch"><Ico name="git-branch" size={15} /><span>{project.currentBranch}</span></span>
    {/if}
  </div>

  {#if config.provider === "antigravity"}<AntigravitySetup />{/if}

  {#if error}
    <p class="err">{error}</p>
  {:else if startsAutomatically}
    <p class="faint small">
      {autoShared.length
        ? tr("Nook kiest bij het starten waar hij draait: deze computer of {machines}.", "Nook picks where it runs as it starts: this computer or {machines}.", { machines: autoShared.map((m) => m.name).join(", ") })
        : tr("Dit project staat nog op geen andere machine, dus hij start op deze computer. Start het één keer op een machine om het daar te delen.", "This project is not on another machine yet, so it starts on this computer. Start it once on a machine to share it there.")}
    </p>
  {:else if machine}
    <p class="faint small">{tr("De agent gebruikt zijn eigen login op {machine}. Hij moet daar geïnstalleerd zijn, en ssh moet er met een sleutel in kunnen.", "The agent uses its own login on {machine}. It must be installed there, and ssh must get in with a key.", { machine: machine.name })}</p>
  {:else if sharing.length && config.isolation === "folder"}
    <p class="note">
      {tr("Er werkt al een sessie in deze map: {sessions}. Twee agents in dezelfde map kunnen elkaars werk overschrijven.", "A session is already working in this folder: {sessions}. Two agents in the same folder can overwrite each other's work.", { sessions: sharing.map((r) => r.title).join(", ") })}
      <label><input type="checkbox" bind:checked={allowShared} /> {tr("Ik weet het, start toch in dezelfde map", "I know, start in the same folder anyway")}</label>
    </p>
  {:else if project && project.verdict !== "ok"}
    <p class="err">{project.verdictMessage}</p>
  {:else if blockingReason && project && config.task}
    <p class="faint small">{blockingReason}</p>
  {:else if project && !project.repoRoot}
    <p class="faint small">{tr("Geen Git-repository: de agent werkt in de map zelf.", "No Git repository: the agent works in the folder itself.")}</p>
  {:else if config.isolation === "worktree" && project?.dirtyFiles}
    <p class="faint small">{tr("Je hebt {n} niet-gecommitte wijzigingen. Die gaan niet mee naar de nieuwe worktree; hij begint vanaf de basis-branch.", "You have {n} uncommitted changes. They don't move to the new worktree; it starts from the base branch.", { n: project.dirtyFiles })}</p>
  {/if}
  <div class="spacer-v"></div>
</div>

<style>
  .new { display: flex; flex-direction: column; gap: var(--space-16); height: 100%; max-width: 640px; margin: 0 auto; width: 100%; }
  .spacer-v { flex: 1; }
  /* The question over the composer (`NewSessionComposer`): the project is the one word you can change, dotted under. */
  .heading-wrap { display: flex; flex-direction: column; align-items: center; gap: var(--space-6); }
  .sub { display: inline-flex; align-items: center; gap: var(--space-4); margin: 0; padding: 0; border: 0; background: none; font: var(--text-body); color: var(--text2); }
  .sub:hover { background: none; text-decoration: underline; text-underline-offset: 3px; }
  .sub.on { color: var(--paper); }
  .heading { font: var(--text-display); color: var(--paper); margin: 0; text-align: center; display: flex; gap: var(--space-6); justify-content: center; align-items: baseline; flex-wrap: wrap; }
  .qmark { margin-left: calc(-1 * var(--space-6)); }
  .project { background: none; border: none; padding: 0; font: inherit; color: var(--paper); text-decoration: underline dashed var(--text3); text-decoration-thickness: 1.5px; text-underline-offset: 5px; }
  .project:hover { background: none; }
  .project.static { text-decoration: none; }
  /* The folder on a machine, typed (`NewSessionComposer.remoteRow`). */
  .remote { display: flex; align-items: center; gap: var(--space-8); width: 100%; max-width: 640px; font: var(--text-body); color: var(--text3); }
  .remote-label { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 45%; }
  .remote input { flex: 1; min-width: 140px; font: var(--text-code); }
  .remote .ghost { flex: none; }
  .faint-pill { color: var(--text3); }
  .clone { display: flex; gap: var(--space-6); }
  .clone input { flex: 1; }
  .box { position: relative; z-index: 1; border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); background: var(--composer); padding: var(--space-16) var(--space-8) var(--space-8) var(--space-16); display: flex; flex-direction: column; gap: var(--space-8); box-shadow: inset 0 1px 0 color-mix(in srgb, var(--paper) 6%, transparent); }
  /* Focus lights the outline a little with the accent (`SessionComposer`: the tint at 28 %). */
  .box:focus-within { border-color: color-mix(in srgb, var(--iris) 28%, var(--composer)); }
  textarea { background: transparent; border: none; resize: none; min-height: 56px; padding: 0; font: var(--text-body); color: var(--paper); }
  textarea::placeholder { color: var(--text3); }
  textarea:focus, textarea:focus-visible { border: none; outline: none; box-shadow: none; }
  .bar, .below { display: flex; align-items: center; gap: var(--space-4); flex-wrap: wrap; }
  .bar { margin-left: calc(-1 * var(--space-8)); }
  .bar :global(.mic) { width: 28px; height: 28px; color: var(--text2); }
  .hint { flex-basis: 100%; order: -1; }
  /* The plus as the Mac's `ComposerIcon`: a 26 pt square, quiet until hovered. */
  .plus { display: grid; place-items: center; width: 26px; height: 26px; flex: none; padding: 0; margin: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .plus:hover, .plus.lit { background: var(--smoke); color: var(--paper); }
  /* Under the box, tucked against it (`ComposerTray`): where the agent works and from which branch. */
  .below { gap: var(--space-6); margin: calc(-1 * var(--space-32)) calc(var(--space-16) + var(--space-6)) 0; padding: calc(var(--space-16) + var(--space-4)) calc(var(--space-8) + var(--space-2)) var(--space-4); border: 1px solid var(--field-stroke); border-radius: 0 0 var(--radius-composer) var(--radius-composer); background: var(--composer-tray); }
  .pill { display: inline-flex; align-items: center; gap: var(--space-6); height: 28px; background: none; border: none; padding: 0 var(--space-8); font: var(--text-control); color: var(--text2); border-radius: var(--radius-control); white-space: nowrap; }
  .pill > :global(svg:last-child:not(:first-child)) { opacity: 0.6; }
  .send { display: grid; place-items: center; width: 32px; height: 32px; padding: 0; border: 0; border-radius: 999px; background: var(--iris); color: var(--on-iris); flex: none; }
  .send:hover:not(:disabled) { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }
  /* Disabled, the Mac's round button is smoke with a tertiary arrow, dimmed by half as a disabled control is. */
  .send:disabled { background: var(--smoke); color: var(--text3); opacity: 0.5; }
  .spin { display: inline-flex; animation: turn 0.9s linear infinite; }
  @keyframes turn { to { transform: rotate(360deg); } }
  .pill:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  .pill.static:hover { background: none; color: var(--text2); }
  .spacer { flex: 1; }
  /* `ComposerDivider`: a gap, not a line. */
  .divider { width: var(--space-4); height: 16px; flex: none; }
  .pop { position: relative; display: inline-block; }
  .menu { position: absolute; top: 30px; left: 0; z-index: 20; background: var(--graphite); border: 1px solid var(--line2); border-radius: 10px; padding: 4px; display: flex; flex-direction: column; min-width: 220px; box-shadow: 0 8px 30px rgba(0, 0, 0, 0.5); font-size: 12.5px; font-weight: 400; text-align: left; }
  .menu button { background: none; border: none; text-align: left; padding: 6px 8px; border-radius: 7px; display: flex; flex-direction: column; gap: 1px; font-size: 12.5px; }
  .menu button:hover:not(:disabled) { background: var(--smoke); }
  .mrow { display: flex; align-items: center; border-radius: 7px; }
  .mrow:hover, .mrow.chosen { background: var(--smoke); }
  .mrow .mitem { flex: 1; min-width: 0; }
  .mrow .mitem:hover { background: none; }
  .mrow .star { opacity: 0; padding: 4px 8px; color: var(--text3); font-size: 13px; align-items: center; justify-content: center; }
  .mrow:hover .star, .mrow .star:focus-visible, .mrow .star.starred { opacity: 1; }
  .mrow .star.starred, .mrow .star:focus-visible { color: var(--paper); }
  .mrow .star:hover { background: none; color: var(--paper); }
  .menu hr { border: none; border-top: 1px solid var(--line2); margin: 4px 0; width: 100%; }
  .mhead { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 4px; }
  .scrolllist { max-height: 240px; overflow-y: auto; display: flex; flex-direction: column; }
  .pill.branch { max-width: 220px; }
  .pill > span { overflow: hidden; text-overflow: ellipsis; }
  .branch-search { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-8); border-bottom: 1px solid var(--line2); color: var(--text3); }
  .branch-search input { flex: 1; min-width: 0; padding: 0; margin: 0; border: 0; outline: 0; background: transparent; font: var(--text-body); color: var(--paper); box-shadow: none; }
  .none { margin: 0; padding: var(--space-8); font: var(--text-detail); color: var(--text3); }
  .small { font-size: 11.5px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  .note { font-size: 12px; color: var(--amber); margin: 0; display: flex; flex-direction: column; gap: 4px; }
</style>
