<script lang="ts">
  // The "Coding agents" step of the first-run flow (`OnboardingAgentsStep` on the Mac): each agent Nook can run, whether
  // it is installed and signed in, with the one button that gets it there (the same install and sign-in commands as
  // Settings › Agents, in a visible terminal), and the git folders you worked in recently to add as projects.
  import { invoke } from "@tauri-apps/api/core";
  import { agentApi, agentNames, type AgentKind, type AgentProfile } from "../lib/agents";
  import { agents } from "../lib/agents.svelte";
  import { workspace } from "../lib/workspace/store.svelte";
  import { ONBOARDING_AGENTS, agentState, readinessAction } from "../lib/agent-readiness";
  import { tr } from "../lib/i18n.svelte";
  import { toast } from "../lib/toast.svelte";
  import AgentMark from "../views/companion/ui/AgentMark.svelte";
  import Ico from "./ui/Ico.svelte";

  let { onsettings }: { onsettings: () => void } = $props();

  interface Candidate { path: string; name: string; parent: string; sessions: number; lastActive: string; added: boolean }

  let profiles = $state<AgentProfile[]>([]);
  let connecting = $state<Record<string, number>>({});
  let candidates = $state<Candidate[]>([]);
  let added = $state<Record<string, boolean>>({});
  let now = $state(Date.now());

  $effect(() => {
    agentApi.profiles().then((p) => (profiles = p)).catch(() => {});
    agents.loadHistory(true);
  });

  // While a terminal is open for an install or sign-in, look again every few seconds; a row stops saying "Connecting"
  // after two minutes, or as soon as the agent is ready.
  $effect(() => {
    if (!Object.keys(connecting).length) return;
    const t = setInterval(() => {
      now = Date.now();
      agents.loadHistory(true);
      agentApi.profiles().then((p) => (profiles = p)).catch(() => {});
    }, 5_000);
    return () => clearInterval(t);
  });

  // The folders the sessions worked in, from the agents' own history and Nook's sessions.
  $effect(() => {
    const sessions = [
      ...(agents.history?.sessions ?? []).map((s) => ({ folder: s.cwd, date: s.ended })),
      ...workspace.runs.map((r) => ({ folder: r.projectPath, date: r.updatedAt })),
    ].filter((s) => s.folder && s.date);
    invoke<Candidate[]>("workspace_project_candidates", { sessions }).then((c) => (candidates = c)).catch(() => (candidates = []));
  });

  function standing(kind: AgentKind) {
    const since = connecting[kind];
    const busy = since !== undefined && now - since < 120_000;
    // Ready wins over a terminal that is still open: the sign-in went through.
    const base = agentState(kind, agents.history, profiles, false);
    return base === "ready" || !busy ? base : "connecting";
  }

  function detail(kind: AgentKind): string {
    switch (standing(kind)) {
      case "checking": return tr("Nook kijkt of hij er is…", "Nook is checking for it…");
      case "connecting": return tr("Bezig in de terminal…", "Working in the terminal…");
      case "signIn": return tr("Geïnstalleerd, nog niet ingelogd", "Installed, not signed in yet");
      case "missing": return tr("Niet op deze computer", "Not on this computer");
      case "ready": return tr("Klaar om te starten", "Ready to start");
    }
  }

  async function connect(kind: AgentKind, install: boolean) {
    const profile = profiles.find((p) => p.kind === kind && p.preferred) ?? profiles.find((p) => p.kind === kind);
    const command = install ? workspace.provider(kind)?.installCommand ?? "" : profile?.loginCommand ?? "";
    if (!command) {
      onsettings();
      return;
    }
    try {
      await agentApi.runInTerminal(command);
      connecting = { ...connecting, [kind]: Date.now() };
      now = Date.now();
    } catch (e) {
      toast.error(tr("Kon de terminal niet openen", "Couldn't open the terminal"), e);
    }
  }

  async function addProject(path: string) {
    try {
      await invoke("workspace_remember_project", { path });
      added = { ...added, [path]: true };
    } catch (e) {
      toast.error(tr("Kon het project niet toevoegen", "Couldn't add the project"), e);
    }
  }
</script>

<h3>{tr("Coding agents", "Coding agents")}</h3>
<p class="muted">{tr("Nook start en volgt je coding agents. Eén die klaar is, is genoeg om te beginnen; installeren en inloggen gebeurt in een terminal die je ziet.", "Nook starts and follows your coding agents. One that is ready is enough to begin; installing and signing in happens in a terminal you can see.")}</p>
<div class="rows">
  {#each ONBOARDING_AGENTS as kind (kind)}
    {@const s = standing(kind)}
    {@const act = readinessAction(s)}
    <div class="row">
      <AgentMark agent={agentNames[kind] ?? kind} size={20} />
      <span class="text">
        <strong>{agentNames[kind] ?? kind}</strong>
        <span class="faint">{detail(kind)}</span>
      </span>
      {#if act === "install"}
        <button class="small" onclick={() => connect(kind, true)}>{tr("Installeer", "Install")}</button>
      {:else if act === "signIn"}
        <button class="small" onclick={() => connect(kind, false)}>{tr("Log in", "Sign in")}</button>
      {:else if s === "ready"}
        <span class="ok" aria-label={tr("Klaar", "Ready")}><Ico name="circle-check" size={16} /></span>
      {:else}
        <span class="faint">…</span>
      {/if}
    </div>
  {/each}
</div>
<button class="link" onclick={onsettings}>{tr("Een andere agent (ACP) toevoegen bij Instellingen › Agents", "Add another agent (ACP) in Settings › Agents")}</button>

{#if candidates.length}
  <h3 class="sub">{tr("Recente projecten", "Recent projects")}</h3>
  <p class="muted">{tr("Git-mappen waar je de afgelopen 30 dagen in werkte. Toevoegen onthoudt ze alleen als project.", "Git folders you worked in over the last 30 days. Adding only remembers them as a project.")}</p>
  <div class="rows">
    {#each candidates as c (c.path)}
      <div class="row">
        <Ico name="folder" size={14} />
        <span class="text">
          <strong>{c.name}</strong>
          <span class="faint path" title={c.path}>{c.parent} · {tr("{n} sessies", "{n} sessions", { n: c.sessions })}</span>
        </span>
        {#if c.added || added[c.path]}
          <span class="ok small"><Ico name="check" size={12} /> {tr("Toegevoegd", "Added")}</span>
        {:else}
          <button class="small" onclick={() => addProject(c.path)}>{tr("Voeg toe", "Add")}</button>
        {/if}
      </div>
    {/each}
  </div>
{/if}

<style>
  h3 { margin: 0; font: var(--text-title); }
  h3.sub { margin-top: var(--space-8); }
  p { margin: 0; }
  .rows { display: flex; flex-direction: column; gap: var(--space-4); }
  .row { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-8) var(--space-12); background: var(--field); border: 1px solid var(--line2); border-radius: var(--radius-card); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .text .faint { font: var(--text-detail); }
  .path { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; direction: rtl; text-align: left; }
  .ok { color: var(--mint); display: inline-flex; align-items: center; gap: var(--space-4); }
  .small { font: var(--text-detail); }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; font: var(--text-detail); text-decoration: underline; align-self: flex-start; }
</style>
