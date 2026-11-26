<script lang="ts">
  import { tip } from "../../components/ui/tip";
  // Settings › Sessions, Worktrees and the workspace for agents (`WorkspaceSettingsSection` on the Mac): one component,
  // shown one part at a time where the Mac has it (`part`).
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agents } from "../../lib/agents.svelte";
  import { permissionLabels, toolsApi, workspaceApi, type PermissionPolicy, type RunProvider, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { automationApi, type AutomationOverview } from "../../lib/workspace/automation";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import Fold from "./Fold.svelte";
  import { catalog } from "../../lib/workspace/models.svelte";
  import { invoke } from "@tauri-apps/api/core";
  import OpenInSettings from "./OpenIn.svelte";
  import SnoozeOptions from "./SnoozeOptions.svelte";
  import { TIMELINE_DETAILS, timelineDetail, type TimelineDetail } from "../../lib/workspace/timeline-detail";
  import { announcementLevel, SCREEN_READER_LEVELS, type ScreenReaderAnnouncements } from "../../lib/workspace/announcements";
  import { api } from "../../lib/api";
  import type { ProviderInfo } from "../../lib/types";
  import TextGeneratorRow from "./TextGeneratorRow.svelte";
  import { textGeneratorSummary, type TextTask } from "../../lib/text-generation";
  import {
    loadRules as loadSettleRules,
    loadSettleActions,
    MAX_DAYS as settleMax,
    MIN_DAYS as settleMin,
    saveRules as saveSettleRules,
    saveSettleActions,
    type AutoSettleRules,
    type SettleActionRules,
  } from "../../lib/auto-settle";

  // The Mac's names for the timeline details and the screen reader levels.
  const detailNames: Record<TimelineDetail, string> = {
    everything: tr("Alles", "Everything"),
    hideSucceeded: tr("Afgeronde stappen verbergen", "Hide finished steps"),
    noTools: tr("Alle stappen verbergen", "Hide all steps"),
    zen: tr("Zen: alleen het gesprek", "Zen: only the conversation"),
  };
  const readerNames: Record<ScreenReaderAnnouncements, string> = {
    off: tr("Uit", "Off"),
    replies: tr("Alleen antwoorden", "Replies only"),
    everything: tr("Stappen en antwoorden", "Steps and replies"),
  };

  // Settling old sessions & settle actions are kept for every window in localStorage, as the snooze options.
  let settleRules = $state<Required<AutoSettleRules>>(loadSettleRules());
  function setSettleRules(next: AutoSettleRules) {
    saveSettleRules(next);
    settleRules = loadSettleRules();
  }

  let settleActions = $state<SettleActionRules>(loadSettleActions());
  function setSettleActions(next: SettleActionRules) {
    saveSettleActions(next);
    settleActions = loadSettleActions();
  }

  // Brain API providers for per-kind text generation (SV-65).
  let brainProviders = $state<ProviderInfo[]>([]);
  $effect(() => {
    if (part === "sessions") api.providers().then((p) => (brainProviders = p)).catch(() => {});
  });

  function setSuggestNextPrompt(v: boolean) {
    if (s) {
      s.suggestNextPrompt = v;
      save();
    }
    try { localStorage.setItem("nook.suggestNextPrompt", v ? "true" : "false"); } catch {}
  }

  function setTextGenerator(task: TextTask, stored: string) {
    if (!s) return;
    s.textGenerators = { ...(s.textGenerators ?? {}), [task]: stored };
    save();
  }

  let { part = "sessions" }: { part?: "sessions" | "worktrees" | "openIn" | "bridge" } = $props();

  let s = $state<WorkspaceSettings | null>(null);
  let error = $state<string | null>(null);
  let linked = $state<string | null>(null);

  $effect(() => {
    workspace.start().then(() => (s = workspace.settings ? { ...workspace.settings } : null));
  });

  let modelListDate = $state<string | null>(null);
  $effect(() => {
    catalog.load();
    invoke<string | null>("workspace_model_list_date").then((d) => (modelListDate = d)).catch(() => {});
  });

  async function save() {
    if (!s) return;
    try {
      await workspaceApi.saveSettings($state.snapshot(s));
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  // Writing titles by itself is stored with the automation settings.
  let automation = $state<AutomationOverview | null>(null);
  $effect(() => {
    if (part === "sessions") automationApi.overview().then((o) => (automation = o)).catch(() => {});
  });
  async function saveAutomation() {
    if (!automation) return;
    try {
      await automationApi.saveSettings($state.snapshot(automation.settings));
    } catch (e) {
      error = String(e);
    }
  }

  /// " Team/Michan " → "team/michan", as the core cleans it (`normalized_branch_prefix`); empty is "nook".
  function normalizedPrefix(raw: string): string {
    const parts = raw.split("/").map((p) => p.trim()).filter((p) => /[\p{L}\p{N}]/u.test(p))
      .map((p) => p.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/, ""))
      .filter(Boolean);
    return parts.length ? parts.join("/") : "nook";
  }

  async function chooseRoot() {
    const picked = await openDialog({ directory: true, multiple: false }).catch(() => null);
    if (typeof picked === "string" && s) {
      s.worktreeRoot = picked;
      save();
    }
  }

  async function link(p: RunProvider) {
    error = null;
    try {
      await toolsApi.linkBridge(p);
      linked = tr("Het commando draait in een terminal van Nook (Agents › Alle terminals).", "The command runs in a Nook terminal (Agents › All terminals).");
      agents.select("terminals");
    } catch (e) {
      error = String(e);
    }
  }

  const providers = $derived(workspace.providers.filter((p) => p.supported));
  const policies = $derived<PermissionPolicy[]>(workspace.provider(s?.defaultProvider ?? "claude")?.capabilities.policies ?? ["acceptEdits"]);
</script>

{#if s && part === "sessions"}
  <!-- Sessions (`WorkspaceSettingsSection`, part sessions): what a new session suggests, the model per agent folded
       away, how sessions behave, what happens when one stops, and tidying up. -->
  <h3>{tr("Nieuwe sessie", "New session")}</h3>
  <p class="section-info">{tr("Wat een nieuwe sessie voorstelt; kies je daar iets anders, dan onthoudt Nook dat.", "What a new session suggests; if you pick something else there, Nook remembers it.")}</p>
  <div class="group">
    <label class="row"><span>{tr("Standaard-agent", "Default agent")}</span>
      <select bind:value={s.defaultProvider} onchange={save}>{#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}</select>
    </label>
    <label class="row"><span>{tr("Standaardmodus", "Default mode")}</span>
      <select bind:value={s.defaultMode} onchange={save}><option value="agent">Agent</option><option value="plan">Plan</option></select>
    </label>
    <label class="row"><span>{tr("Standaardrechten", "Default permissions")}</span>
      <select bind:value={s.defaultPermission} onchange={save}>{#each policies as p (p)}<option value={p}>{permissionLabels[p]}</option>{/each}</select>
    </label>
    <label class="row"><span>{tr("Standaard-isolatie", "Default isolation")}</span>
      <select bind:value={s.defaultIsolation} onchange={save}><option value="worktree">{tr("Nieuwe Git-worktree", "New Git worktree")}</option><option value="folder">{tr("Huidige map", "Current folder")}</option></select>
    </label>
  </div>

  <Fold title={tr("Model per agent", "Model per agent")} summary={s.defaultModels[s.defaultProvider] || tr("standaard", "default")}>
    {#each providers as p (p.provider)}
      {@const saved = s.defaultModels[p.provider] ?? ""}
      {@const choices = (catalog.byAgent[p.provider] ?? []).filter((m) => m.current || m.id === saved)}
      <label class="row"><span class="agent-name"><AgentMark agent={p.name} size={14} />{p.name}</span>
        {#if choices.length}
          <select class="model" value={saved} onchange={(e) => { s!.defaultModels[p.provider] = e.currentTarget.value; save(); }}>
            <option value="">{tr("standaard", "default")}</option>
            {#each choices as m (m.id)}<option value={m.id}>{m.name}</option>{/each}
            {#if saved && !choices.some((m) => m.id === saved)}<option value={saved}>{saved}</option>{/if}
          </select>
        {:else}
          <input class="model" placeholder={tr("standaard", "default")} value={saved} onchange={(e) => { s!.defaultModels[p.provider] = (e.target as HTMLInputElement).value.trim(); save(); }} />
        {/if}
      </label>
    {/each}
    <!-- Off: the model list that came with the app is used, and nothing goes online for it. -->
    <label class="row"><span>{tr("Online naar nieuwe modellen zoeken", "Check for new models online")}<br /><small>{tr("Nook haalt zijn lijst met modellen op uit zijn GitHub-opslagplaats, zodat nieuwe modellen en de agent-update die ze vragen tussen versies verschijnen. Uit: alleen de lijst die met de app kwam.", "Nook fetches its model list from its GitHub repository, so new models and the agent update they need appear between releases. Off: only the list that came with the app is used.")}{#if modelListDate} {tr("Lijst van {date}.", "List from {date}.", { date: modelListDate })}{/if}</small></span>
      <input type="checkbox" role="switch" checked={s.onlineModelList !== false} onchange={(e) => { s!.onlineModelList = e.currentTarget.checked; save(); }} />
    </label>
  </Fold>

  <h3>{tr("Gedrag", "Behavior")}</h3>
  <div class="group">
    {#if automation}
      <label class="row"><span>{tr("Sessietitels automatisch laten schrijven (klein model)", "Write session titles automatically (small model)")}</span>
        <input type="checkbox" role="switch" bind:checked={automation.settings.autoTitles} onchange={saveAutomation} />
      </label>
      <label class="row stacked">
        <span>{tr("Eigen regels voor titels", "Your own rules for titles")}</span>
        <input placeholder={tr("Begin met het ticketnummer, schrijf in het Engels", "Start with the ticket number, write in English")}
          value={automation.settings.titleInstructions ?? ""} onchange={(e) => { automation!.settings.titleInstructions = e.currentTarget.value.trim(); saveAutomation(); }} />
      </label>
    {/if}
    <label class="row">
      <span>{tr("Volgende prompt voorstellen", "Suggest the next prompt")}<br /><small>{tr("Stelt na een antwoord van de agent een vervolgbericht voor in het lege invoerveld (Tab neemt over, Esc verbergt).", "Suggests a follow-up prompt in the empty composer after the agent replies (Tab accepts, Esc dismisses).")}</small></span>
      <input type="checkbox" role="switch" checked={s.suggestNextPrompt !== false} onchange={(e) => setSuggestNextPrompt(e.currentTarget.checked)} />
    </label>
    <Fold
      title={tr("Tekstgeneratie", "Text generation")}
      summary={textGeneratorSummary(s.textGenerators, brainProviders, tr("Coding agent", "Coding agent"), tr("Claude · API-sleutel", "Claude · API key"))}
    >
      <p class="note">{tr(
        "Wie de korte teksten schrijft die Nook vraagt: sessietitels, commitberichten en pull requests, en de voorgestelde volgende prompt. De CLI van de coding agent gebruikt je abonnement; een model-API gebruikt zijn eigen sleutel en start nooit een agent.",
        "Who writes the short texts Nook asks for: session titles, commit messages and pull requests, and the suggested next prompt. The coding agent's CLI uses your subscription; a model API uses its own key and never starts an agent.",
      )}</p>
      <TextGeneratorRow
        label={tr("Sessietitels", "Session titles")}
        value={s.textGenerators?.titles ?? "agent"}
        providers={brainProviders}
        onchange={(v) => setTextGenerator("titles", v)}
      />
      <TextGeneratorRow
        label={tr("Tekst voor commits en pull requests", "Commit and pull request text")}
        value={s.textGenerators?.gitText ?? "agent"}
        providers={brainProviders}
        onchange={(v) => setTextGenerator("gitText", v)}
      />
      <TextGeneratorRow
        label={tr("Voorgestelde volgende prompt", "Suggested next prompt")}
        value={s.textGenerators?.nextPrompt ?? "agent"}
        providers={brainProviders}
        onchange={(v) => setTextGenerator("nextPrompt", v)}
      />
    </Fold>
    <label class="row stacked">
      <span>{tr("Instructies voor elke agent", "Instructions for every agent")}<br /><small>{tr("Nook geeft ze bij de start aan elke coding agent, voor de eigen instructies van de sessie, ook aan agents die geen CLAUDE.md of AGENTS.md lezen. Een wijziging telt vanaf de volgende start van een agent.", "Nook gives these to every coding agent at launch, before the session's own instructions, also to agents that read no CLAUDE.md or AGENTS.md. A change counts from an agent's next start.")}</small></span>
      <textarea rows="3" placeholder={tr("Regels die elke agent hier volgt, bijv. “Draai de tests voor je commit.”", "Rules every agent follows here, e.g. “Run the tests before you commit.”")}
        value={s.agentInstructions ?? ""} onchange={(e) => { s!.agentInstructions = e.currentTarget.value.trim(); save(); }}></textarea>
    </label>
    <label class="row"><span>{tr("Een bericht tijdens een beurt stuurt de agent bij (Ctrl+Enter zet het in de wachtrij)", "A message during a turn steers the agent (Ctrl+Enter queues it)")}</span><input type="checkbox" role="switch" bind:checked={s.steerByDefault} onchange={save} /></label>
    <!-- How much of the agent's work a timeline shows (`TimelineDetail`; applied in `lib/workspace/timeline-detail.ts`). -->
    <label class="row">
      <span>{tr("Werk van de agent in de tijdlijn", "Agent's work in the timeline")}<br /><small>{tr("Hoeveel van de stappen van de agent een sessie laat zien. Verzoeken die op jou wachten en fouten blijven altijd staan.", "How much of the agent's steps a session shows. Requests that wait on you and errors always stay.")}</small></span>
      <select value={timelineDetail(s.timelineDetail)} onchange={(e) => { s!.timelineDetail = e.currentTarget.value; save(); }}>
        {#each TIMELINE_DETAILS as d (d)}<option value={d}>{detailNames[d]}</option>{/each}
      </select>
    </label>
    <!-- Only heard while a screen reader runs, and only from the session on screen (`components/SessionAnnouncer.svelte`). -->
    <label class="row">
      <span>{tr("Meldingen voor schermlezers", "Screen reader announcements")}<br /><small>{tr("Wat een schermlezer hoort van de sessie die je bekijkt, alleen terwijl een schermlezer draait. Alleen antwoorden leest elk antwoord dat de agent afmaakt en zegt wanneer hij je goedkeuring nodig heeft of je iets vraagt. Stappen en antwoorden zegt ook de stap waarmee hij bezig is, zoals het bestand dat hij bewerkt; stappen komen met tussenpozen, dus een snelle stap kan wegvallen. Zijn denkwerk wordt nooit voorgelezen.", "What a screen reader hears from the session you are looking at, only while a screen reader runs. Replies only reads each reply the agent finishes and says when it needs your approval or asks you something. Steps and replies also says the step it is on, such as the file it edits; steps are spaced out, so a quick one can be skipped. Its thinking is never read.")}</small></span>
      <select value={announcementLevel(s.screenReaderAnnouncements)} onchange={(e) => { s!.screenReaderAnnouncements = e.currentTarget.value; save(); }}>
        {#each SCREEN_READER_LEVELS as l (l)}<option value={l}>{readerNames[l]}</option>{/each}
      </select>
    </label>
    <label class="row">
      <span>{tr("Sessies tegelijk aan het werk", "Sessions working at once")}<br /><small>{tr("Hooguit zoveel sessies werken tegelijk; een nieuwe beurt daarboven wacht en start zodra de beurt van een andere sessie klaar is.", "At most this many sessions work at the same time; a new turn past it waits and starts as soon as another session's turn ends.")}</small></span>
      <select value={s.maxWorkingSessions ?? 0} onchange={(e) => { s!.maxWorkingSessions = Number(e.currentTarget.value); save(); }}>
        <option value={0}>{tr("Geen limiet", "No limit")}</option>
        {#each [2, 3, 4, 6, 8] as count (count)}<option value={count}>{count}</option>{/each}
      </select>
    </label>
  </div>

  <h3>{tr("Als een sessie stopt of Nook herstart", "When a session stops or Nook restarts")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Na een gebruikslimiet vanzelf verdergaan zodra die vrij is", "Resume automatically once a usage limit resets")}</span><input type="checkbox" role="switch" bind:checked={s.autoResumeLimited} onchange={save} /></label>
    <label class="row"><span>{tr("Een sessie die stopte doordat je Nook afsloot of herstartte gaat vanzelf verder zodra je Nook weer opent", "Continue a session that quitting or restarting Nook stopped when you open Nook again")}</span><input type="checkbox" role="switch" bind:checked={s.continueAfterRelaunch} onchange={save} /></label>
  </div>

  <h3>{tr("Opruimen", "Tidying up")}</h3>
  <div class="group">
    <!-- `AutoSettleRulesRows` on the Mac; applied by the Agents list (`lib/auto-settle.ts`, AG-110 & AG-111). -->
    <label class="row"><span>{tr("Oude sessies automatisch afhandelen", "Settle old sessions automatically")}</span>
      <input type="checkbox" role="switch" checked={settleRules.enabled} onchange={(e) => setSettleRules({ ...settleRules, enabled: e.currentTarget.checked })} />
    </label>
    {#if settleRules.enabled}
      <label class="row"><span>{tr("Na {n} dagen stil", "After {n} days of quiet", { n: settleRules.inactivityDays })}</span>
        <input class="days" type="number" min={settleMin} max={settleMax} value={settleRules.inactivityDays}
          aria-label={tr("Dagen stil", "Days of quiet")}
          onchange={(e) => { setSettleRules({ ...settleRules, inactivityDays: Number(e.currentTarget.value) }); e.currentTarget.value = String(settleRules.inactivityDays); }} />
      </label>
      <label class="row"><span>{tr("Afhandelen zodra de pull request is samengevoegd", "Settle when pull request is merged")}</span>
        <input type="checkbox" role="switch" checked={settleRules.settleOnMergedPullRequest} onchange={(e) => setSettleRules({ ...settleRules, settleOnMergedPullRequest: e.currentTarget.checked })} />
      </label>
      <label class="row"><span>{tr("Afhandelen zodra de pull request is gesloten", "Settle when pull request is closed")}</span>
        <input type="checkbox" role="switch" checked={settleRules.settleOnClosedPullRequest} onchange={(e) => setSettleRules({ ...settleRules, settleOnClosedPullRequest: e.currentTarget.checked })} />
      </label>
      <label class="row"><span>{tr("Openhouden zolang er een open pull request is", "Keep in inbox while pull request is open")}</span>
        <input type="checkbox" role="switch" checked={settleRules.keepWithOpenPullRequest} onchange={(e) => setSettleRules({ ...settleRules, keepWithOpenPullRequest: e.currentTarget.checked })} />
      </label>
    {/if}
    <label class="row"><span>{tr("Devservers stoppen bij afhandelen", "Stop dev servers when settling")}<br /><small>{tr("Stopt lokale servers die bij de map horen zodra de laatste open sessie in die map wordt afgehandeld.", "Stops local dev servers in the session's folder when the last unsettled session in that folder settles.")}</small></span>
      <input type="checkbox" role="switch" checked={settleActions.stopDevServersOnSettle} onchange={(e) => setSettleActions({ ...settleActions, stopDevServersOnSettle: e.currentTarget.checked })} />
    </label>
    <label class="row"><span>{tr("Stille terminals sluiten bij afhandelen", "Close idle terminals when settling")}</span>
      <input type="checkbox" role="switch" checked={settleActions.closeIdleTerminalsOnSettle} onchange={(e) => setSettleActions({ ...settleActions, closeIdleTerminalsOnSettle: e.currentTarget.checked })} />
    </label>
    <label class="row stacked">
      <span>{tr("Commando uitvoeren bij afhandelen", "Run command when settling")}<br /><small>{tr("Draait in de map van de sessie zodra de laatste open sessie daar wordt afgehandeld.", "Runs in the session's working folder when the last unsettled session there settles.")}</small></span>
      <input placeholder={tr("bijv. docker compose stop", "e.g. docker compose stop")} value={settleActions.settleCommand}
        onchange={(e) => setSettleActions({ ...settleActions, settleCommand: e.currentTarget.value.trim() })} />
    </label>
    <label class="row"><span>{tr("Automatisch archiveren na", "Archive automatically after")}</span>
      <select bind:value={s.autoArchiveDays} onchange={save}>
        <option value={0}>{tr("Nooit", "Never")}</option><option value={1}>{tr("1 dag", "1 day")}</option>{#each [7, 30, 90] as n (n)}<option value={n}>{tr("{n} dagen", "{n} days", { n })}</option>{/each}
      </select>
    </label>
  </div>
  {#if error}<p class="err">{error}</p>{/if}

  <!-- What every snooze menu offers, last on the page as on the Mac (`SnoozeOptionsSection`). -->
  <SnoozeOptions />
{:else if s && part === "worktrees"}
  <!-- Worktrees (part worktrees): where a new worktree goes. -->
  <h3>{tr("Nieuwe worktrees", "New worktrees")}</h3>
  <div class="group">
    <div class="row"><span>{tr("Map voor worktrees", "Worktree folder")}</span>
      <span class="inline"><span class="path">{s.worktreeRoot || "~/.nook/worktrees"}</span><button class="small" onclick={chooseRoot}>{tr("Wijzig…", "Change…")}</button>
        {#if s.worktreeRoot}<button class="small" onclick={() => { s!.worktreeRoot = ""; save(); }}>{tr("Standaard", "Default")}</button>{/if}</span>
    </div>
    <div class="row">
      <span>{tr("Prefix voor branches", "Branch prefix")}</span>
      <span class="inline">
        <input class="prefix" placeholder="nook" aria-label={tr("Prefix voor branches", "Branch prefix")} value={s.branchPrefix ?? "nook"}
          onchange={(e) => { s!.branchPrefix = normalizedPrefix(e.currentTarget.value); e.currentTarget.value = s!.branchPrefix; save(); }} />
        <span class="example">{tr("bijv. {prefix}/fix-login-3fa2", "e.g. {prefix}/fix-login-3fa2", { prefix: normalizedPrefix(s.branchPrefix ?? "nook") })}</span>
      </span>
    </div>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else if part === "openIn"}
  <!-- Editor & browser (part openIn): its own component, with Nook's browser. -->
  <OpenInSettings />
{:else if s && part === "bridge"}
  <!-- Workspace for agents (`bridge`, on Automation): Nook's terminal, browser and pull requests for agents. -->
  <h3>{tr("Werkruimte voor agents", "Workspace for agents")}</h3>
  <p class="section-info">{tr("Sessies die Nook start krijgen dit vanzelf: de agent kan een devserver draaien, een pagina in Nooks browser controleren en een pull request voorstellen. Riskante commando's en elke pull request vragen eerst je OK. De knoppen geven Claude Code, Codex of Gemini CLI die je zelf start hetzelfde.", "Sessions Nook starts get this by themselves: the agent can run a dev server, check a page in Nook's browser and propose a pull request. Risky commands and every pull request ask your OK first. The buttons give Claude Code, Codex or Gemini CLI you start yourself the same.")}</p>
  <div class="group">
    <label class="row"><span>{tr("Agents mogen de terminal, browser en pull requests van Nook gebruiken", "Agents may use Nook's terminal, browser and pull requests")}</span><input type="checkbox" role="switch" bind:checked={s.agentTools} onchange={save} /></label>
    <div class="row"><span>{tr("Ook voor agents buiten Nook", "Also for agents outside Nook")}</span>
      <span class="inline">
        {#each ["claude", "codex", "gemini"] as p (p)}
          <button class="agent small" disabled={!s.agentTools} use:tip={tr("Draait het koppelcommando zichtbaar in een terminal van Nook", "Runs the link command visibly in a Nook terminal")} onclick={() => link(p as RunProvider)}><AgentMark agent={workspace.provider(p)?.name ?? p} size={12} />{workspace.provider(p)?.name ?? p}</button>
        {/each}
      </span>
    </div>
    {#if linked}<p class="note ok">{linked}</p>{/if}
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else if !s}
  <p class="faint">{tr("Laden…", "Loading…")}</p>
{/if}

<style>
  .inline { display: flex; gap: var(--space-8); align-items: center; }
  .path { font: var(--text-code); color: var(--text2); }
  .model { width: 220px; }
  .prefix { width: 160px; }
  .days { width: 64px; }
  .stacked textarea, .stacked input { width: 100%; resize: vertical; font: var(--text-body); }
  .example { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .agent-name { display: inline-flex; align-items: center; gap: var(--space-6); }
  .agent { display: inline-flex; align-items: center; gap: var(--space-4); }
  .ok { color: var(--mint) !important; }
  .err { color: var(--coral); font: var(--text-detail); }
</style>
