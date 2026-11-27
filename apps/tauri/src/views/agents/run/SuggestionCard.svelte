<script lang="ts">
  // A new session the agent suggests (`SessionSuggestionCard` on the Mac): "New session" on top, the title, where it
  // would run and the summary, and Options, Do it here and Start; × dismisses it. Once chosen it folds to one line.
  import { tr } from "../../../lib/i18n.svelte";
  import { agents } from "../../../lib/agents.svelte";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { workspaceApi, type RunEvent, type WorkspaceRun } from "../../../lib/workspace/api";
  import { namedProvider, sessionCardsApi, suggestedConfig, suggestionOf, type SuggestionChoice } from "../../../lib/workspace/session-cards";
  import { openNewSessionIn } from "../new-session.svelte";
  import BusyLine from "../../../components/ui/BusyLine.svelte";
  import IconButton from "../../../components/ui/IconButton.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import { toast } from "../../../lib/toast.svelte";

  let { run, event }: { run: WorkspaceRun; event: RunEvent } = $props();
  const suggestion = $derived(suggestionOf(event));
  let starting = $state(false);

  const agent = $derived(suggestion ? namedProvider(suggestion.agent, workspace.providers) : null);
  const place = $derived.by(() => {
    if (!suggestion) return "";
    const where = suggestion.worktree === true ? tr("Nieuwe worktree", "New worktree") : suggestion.worktree === false ? tr("Huidige map", "Current checkout") : tr("Standaard van het project", "Project default");
    const name = agent ? workspace.provider(agent)?.name : null;
    return name ? `${name} · ${where}` : where;
  });

  async function choose(choice: SuggestionChoice) {
    if (!suggestion) return;
    try {
      if (choice === "start") {
        starting = true;
        const provider = agent ?? run.provider;
        const settings = workspace.settings;
        const config = suggestedConfig(suggestion, run, provider, workspace.provider(provider)?.capabilities.policies ?? ["ask"], {
          models: settings?.defaultModels ?? {},
          profiles: settings?.defaultProfiles ?? {},
          efforts: settings?.defaultEfforts ?? {},
          isolation: settings?.defaultIsolation,
          permission: settings?.defaultPermission,
          worktreeRoot: settings?.worktreeRoot,
          folderChoices: settings?.folderChoices,
        });
        if (config.isolation === "worktree" && !config.baseBranch && config.projectPath) {
          const info = await workspaceApi.inspect(config.projectPath).catch(() => null);
          config.baseBranch = info?.currentBranch || info?.defaultBase || info?.branches[0] || "";
        }
        const id = await workspaceApi.start(config, true);
        await sessionCardsApi.chosen(run.id, event.id, "start", id);
        toast.show(tr("Sessie gestart", "Session started"), "success", suggestion.title, {
          label: tr("Openen", "Open"),
          run: () => agents.select(`run:${id}`),
        });
      } else if (choice === "here") {
        await workspaceApi.send(run.id, suggestion.prompt);
        await sessionCardsApi.chosen(run.id, event.id, "here");
      } else if (choice === "options") {
        const folder = (run.projectPath || run.workingDirectory).replace(/[\\/]+$/, "");
        try { localStorage.setItem(`nook.newSession.draft:${folder}`, suggestion.prompt); } catch { /* opens without the task */ }
        agents.select("new");
        await openNewSessionIn(folder);
      } else {
        await sessionCardsApi.chosen(run.id, event.id, "dismiss");
      }
    } catch (e) {
      if (choice === "start") {
        toast.error(tr("Kon de sessie niet starten", "Couldn’t start the session"), e);
      } else {
        toast.show(String(e));
      }
    } finally {
      starting = false;
    }
  }
</script>

{#if suggestion}
  <div class="suggestion">
    {#if (event.state === "pending" || !event.state) && !starting}
      <div class="card" role="group" aria-label={`${tr("Nieuwe sessie", "New session")}: ${suggestion.title}`}>
        <div class="header">{tr("Nieuwe sessie", "New session")}</div>
        <div class="body">
          <div class="top">
            <div class="words">
              <div class="title">{suggestion.title}</div>
              <div class="place"><span class="where">{place}</span>{#if suggestion.summary}<span class="summary"> · {suggestion.summary}</span>{/if}</div>
            </div>
            <IconButton title={tr("Negeren", "Dismiss")} onclick={() => choose("dismiss")}><Ico name="x" size={13} /></IconButton>
          </div>
          <div class="buttons">
            <button type="button" class="ghost small" onclick={() => choose("options")}>{tr("Opties", "Options")}</button>
            <span class="grow"></span>
            <button type="button" class="ghost small" onclick={() => choose("here")}>{tr("Doe het hier", "Do it here")}</button>
            <button type="button" class="primary small" onclick={() => choose("start")}>{tr("Start", "Start")}</button>
          </div>
        </div>
      </div>
    {:else}
      <div class="outcome">
        {#if starting || event.state === "running"}
          <BusyLine text={tr("“{title}” starten…", "Starting “{title}”…", { title: suggestion.title })} tone="inherit" />
        {:else if event.state === "done"}
          <span class="ok"><Ico name="circle-check" size={13} /></span>
          <span class="line">{tr("“{title}” gestart als nieuwe sessie", "Started “{title}” as a new session", { title: suggestion.title })}</span>
          {#if event.output && workspace.runs.some((r) => r.id === event.output)}<button type="button" class="ghost small" onclick={() => agents.select(`run:${event.output}`)}>{tr("Openen", "Open")}</button>{/if}
        {:else if event.state === "allowed"}
          <span class="faint"><Ico name="corner-down-left" size={13} /></span>
          <span class="line">{tr("“{title}” ging naar deze sessie", "“{title}” went to this session", { title: suggestion.title })}</span>
        {:else}
          <span class="faint"><Ico name="x" size={13} /></span>
          <span class="line">{tr("“{title}” genegeerd", "Dismissed “{title}”", { title: suggestion.title })}</span>
        {/if}
      </div>
    {/if}
  </div>
{/if}

<style>
  .suggestion { max-width: 560px; padding: var(--space-4) 0; }
  .card { border-radius: var(--radius-card); background: var(--graphite); border: 1px solid var(--line); overflow: hidden; }
  .header { font: var(--text-label); color: var(--text2); padding: var(--space-8) var(--space-12); background: var(--smoke); }
  .body { padding: var(--space-12); display: flex; flex-direction: column; gap: var(--space-8); }
  .top { display: flex; align-items: flex-start; gap: var(--space-8); }
  .words { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-4); }
  .title { font: var(--text-emphasis); color: var(--paper); }
  .place { font: var(--text-body); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .where { color: var(--text-strong); }
  .summary { color: var(--text3); }
  .buttons { display: flex; align-items: center; gap: var(--space-8); }
  .grow { flex: 1; }
  button.small { height: 30px; padding: 0 var(--space-12); font: var(--text-emphasis); }
  button.ghost.small { padding: 0 10px; color: var(--text2); }
  button.ghost.small:hover { color: var(--paper); background: var(--graphite); }
  .outcome { display: flex; align-items: center; gap: var(--space-6); font: var(--text-detail); color: var(--text2); white-space: nowrap; }
  .line { overflow: hidden; text-overflow: ellipsis; }
  .ok { color: var(--mint); display: inline-flex; }
  .faint { color: var(--text3); display: inline-flex; }
</style>
