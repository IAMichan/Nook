<script lang="ts">
  // Agents › Actions (`ActionsPanel` on the Mac): the GitHub Actions runs of one repository, so a CI run or a promote
  // can be followed without a pull request in between. Pick the repository at the top, narrow the runs to a workflow
  // or to the running or failed ones, and open a run beside the list (in its place when the window is narrow) to see
  // its jobs, re-run or cancel it, and read a job's log. The list is read again every ten seconds while something in
  // it runs, and every minute otherwise.
  import { untrack } from "svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import {
    actionsApi, candidateRepos, eventName, isLive, parseRepo, runClock, statusFilterName,
    type ActionsRepo, type RunStatusFilter, type Workflow, type WorkflowRun,
  } from "../../../lib/actions";
  import { api } from "../../../lib/api";
  import { tr } from "../../../lib/i18n.svelte";
  import RunSkeleton from "./RunSkeleton.svelte";
  import { pullRequests } from "../../../lib/pulls.svelte";
  import { ago } from "../time";
  import RepoPicker from "./RepoPicker.svelte";
  import RunMark from "./RunMark.svelte";
  import RunView from "./RunView.svelte";

  const REPO_KEY = "agents.actions.repo";
  const TYPED_KEY = "agents.actions.typed";
  const TYPED_LIMIT = 10;
  const STATUSES: RunStatusFilter[] = ["all", "running", "failed"];

  let pushed = $state<ActionsRepo[]>([]);
  let available = $state(true);
  let reposLoaded = $state(false);
  let typed = $state<string[]>(readTyped());
  let repo = $state<string | null>(read(REPO_KEY));
  let workflows = $state<Workflow[]>([]);
  let workflow = $state<number | null>(null);
  let status = $state<RunStatusFilter>("all");
  let runs = $state<WorkflowRun[]>([]);
  /// The account that could read the repository; the run and its job logs are read with it too.
  let account = $state<string | null>(null);
  let loaded = $state(false);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let opened = $state<WorkflowRun | null>(null);
  let width = $state(0);
  let now = $state(Date.now());
  // Bumped to read the list again at once (the refresh button, an action in a run).
  let reload = $state(0);

  const repos = $derived(candidateRepos(pushed, pullRequests.accounts, typed));
  const wide = $derived(width >= 760);
  const anyLive = $derived(runs.some(isLive));
  // The run beside the list keeps up with the list's copy, so its row and its header agree.
  const openedRun = $derived(opened ? (runs.find((r) => r.id === opened!.id) ?? opened) : null);

  function read(key: string): string | null {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  }

  function readTyped(): string[] {
    try {
      const list = JSON.parse(localStorage.getItem(TYPED_KEY) ?? "[]");
      return Array.isArray(list) ? list.filter((x): x is string => typeof x === "string" && parseRepo(x) === x) : [];
    } catch {
      return [];
    }
  }

  function write(key: string, value: string) {
    try {
      localStorage.setItem(key, value);
    } catch {
      // Only remembers the choice for next time.
    }
  }

  function pick(name: string) {
    if (!repos.some((r) => r.name === name)) {
      typed = [name, ...typed.filter((t) => t !== name)].slice(0, TYPED_LIMIT);
      write(TYPED_KEY, JSON.stringify(typed));
    }
    if (name === repo) return;
    repo = name;
    write(REPO_KEY, name);
  }

  // The picker's lists: your recently pushed repositories, and the pull requests Nook already knows.
  $effect(() => {
    pullRequests.refresh();
    actionsApi
      .repos()
      .then((r) => {
        pushed = r.repos;
        available = r.available;
      })
      .catch(() => {
        // Only the picker's suggestions; the run list says what went wrong with the repository itself.
      })
      .finally(() => (reposLoaded = true));
  });

  // Without a remembered choice, the repository you pushed to last.
  $effect(() => {
    if (!repo && repos.length) repo = repos[0].name;
  });

  // Another repository: its own workflows, the filters back to all, the run closed.
  $effect(() => {
    const name = repo;
    workflows = [];
    workflow = null;
    opened = null;
    runs = [];
    loaded = false;
    // Read without tracking: the picker's list grows while it loads, which is no reason to start over.
    account = untrack(() => repos.find((r) => r.name === name)?.account ?? null);
    if (!name) return;
    let cancelled = false;
    actionsApi
      .workflows(untrack(() => account), name)
      .then((list) => !cancelled && (workflows = list))
      .catch(() => {
        // The chips are a shortcut; the run list says what went wrong.
      });
    return () => (cancelled = true);
  });

  // The runs: read now, and again while the page is open; sooner while one of them runs.
  $effect(() => {
    void reload;
    const name = repo, flow = workflow, filter = status;
    if (!name) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    // Failed reads in a row: a passing one (no connection for a moment, GitHub slow) is tried again soon and only
    // shows when it happens twice.
    let failures = 0;
    const fetchRuns = async () => {
      // A hidden window does not need fresh runs; the next tick after it shows again reads them.
      if (!document.hidden) {
        loading = true;
        try {
          // The account that read it last is tried first, without making each answer start the reading over.
          const fresh = await actionsApi.runs(untrack(() => account), name, flow, filter);
          if (cancelled) return;
          runs = fresh.runs;
          account = fresh.account;
          error = null;
          failures = 0;
        } catch (e) {
          if (cancelled) return;
          failures += 1;
          if (failures >= 2) error = String(e);
        } finally {
          if (!cancelled) {
            loading = false;
            if (failures !== 1) loaded = true;
          }
        }
      }
      timer = setTimeout(fetchRuns, failures === 1 ? 1_500 : runs.some(isLive) ? 10_000 : 60_000);
    };
    fetchRuns();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  });

  // The clocks of running runs count up each second; the relative times move on once a minute.
  $effect(() => {
    const tick = setInterval(() => (now = Date.now()), anyLive ? 1000 : 60_000);
    return () => clearInterval(tick);
  });

  function openSettings() {
    write("settings.section", "accounts");
    api.showMain("settings");
  }

  function open(url: string) {
    if (/^https:\/\//.test(url)) openUrl(url);
  }

  const notConnected = $derived(reposLoaded && !available && !pullRequests.accounts.length);
</script>

<div class="actions" bind:clientWidth={width}>
  {#if openedRun && !wide}
    {#key openedRun.id}
      <RunView repo={repo ?? ""} {account} run={openedRun} narrow onclose={() => (opened = null)} onchanged={() => reload++} />
    {/key}
  {:else}
    <div class="head">
      <strong>Actions</strong>
      <RepoPicker {repos} value={repo} onpick={pick} />
      <span class="spacer"></span>
      <!-- A first read has the list's skeleton; this only marks a refresh. -->
      {#if loading && loaded}<span class="faint small">{tr("Bezig…", "Loading…")}</span>{/if}
      <button class="ghost" title={tr("Vernieuwen", "Refresh")} disabled={!repo || loading} onclick={() => reload++}>{tr("Vernieuwen", "Refresh")}</button>
      {#if repo}<button class="ghost" title={tr("Open de Actions van deze repository op GitHub", "Open this repository's Actions on GitHub")} onclick={() => open(`https://github.com/${repo}/actions`)}>{tr("Open op GitHub", "Open on GitHub")} ↗</button>{/if}
    </div>

    {#if notConnected}
      {@render empty(
        tr("GitHub is nog niet gekoppeld", "GitHub is not connected yet"),
        tr("Koppel je GitHub-account onder Instellingen › Accounts & koppelingen, dan zie je hier de workflow-runs van je repositories.", "Connect your GitHub account under Settings › Accounts & connections to see your repositories' workflow runs here."),
        [tr("Koppel GitHub", "Connect GitHub"), openSettings],
      )}
    {:else if !repo}
      {#if reposLoaded}
        {@render empty(tr("Kies een repository", "Choose a repository"), tr("Kies er een in de lijst hierboven, of typ eigenaar/naam.", "Pick one in the list above, or type owner/name."))}
      {:else}
        <RunSkeleton />
      {/if}
    {:else}
      <div class="filters">
        <div class="chips">
          <button class="chip" class:on={workflow === null} onclick={() => (workflow = null)}>{tr("Alle", "All")}</button>
          {#each workflows as w (w.id)}
            <button class="chip" class:on={workflow === w.id} title={w.path} onclick={() => (workflow = w.id)}>{w.name}</button>
          {/each}
        </div>
        <div class="segment" role="radiogroup" aria-label={tr("Status", "Status")}>
          {#each STATUSES as s (s)}
            <button role="radio" aria-checked={status === s} class:on={status === s} onclick={() => (status = s)}>{statusFilterName(s)}</button>
          {/each}
        </div>
      </div>

      <div class="body" class:split={wide && openedRun}>
        <div class="list">
          {#if error && !runs.length}
            <p class="err">{error}</p>
          {:else if !loaded}
            <RunSkeleton />
          {:else if !runs.length}
            {#if workflow !== null || status !== "all"}
              {@render empty(tr("Geen runs gevonden", "No runs found"), tr("Niets past bij dit filter.", "Nothing matches this filter."), [tr("Wis filter", "Clear filter"), () => ((workflow = null), (status = "all"))])}
            {:else}
              {@render empty(tr("Nog geen workflow-runs", "No workflow runs yet"), tr("Deze repository heeft nog niets gedraaid met GitHub Actions.", "Nothing has run with GitHub Actions in this repository yet."))}
            {/if}
          {:else}
            {#if error}<p class="err">{error}</p>{/if}
            {#each runs as run (run.id)}
              {@render row(run)}
            {/each}
          {/if}
        </div>
        {#if wide && openedRun}
          <div class="side">
            {#key openedRun.id}
              <RunView repo={repo ?? ""} {account} run={openedRun} onclose={() => (opened = null)} onchanged={() => reload++} />
            {/key}
          </div>
        {/if}
      </div>
    {/if}
  {/if}
</div>

{#snippet row(run: WorkflowRun)}
  {@const clock = runClock(run, now)}
  <button class="row" class:on={openedRun?.id === run.id} title={tr("Bekijk run", "View run")} onclick={() => (opened = run)}>
    <RunMark outcome={run.outcome} running={run.running} />
    <span class="text">
      <span class="name">{run.title}</span>
      <span class="meta faint">
        {run.workflow} · #{run.number}{#if run.branch} · <span class="mono">{run.branch}</span>{/if} · {eventName(run.event)}{#if run.actor} · @{run.actor}{/if}{#if run.created} · {ago(run.created, now)}{/if}{#if clock} · <span class="mono">{clock}</span>{/if}
      </span>
    </span>
    <span class="chevron faint">›</span>
  </button>
{/snippet}

{#snippet empty(title: string, detail: string, action?: [string, () => void])}
  <div class="empty">
    <strong>{title}</strong>
    <span class="muted small">{detail}</span>
    {#if action}<button class="primary" onclick={action[1]}>{action[0]}</button>{/if}
  </div>
{/snippet}

<style>
  .actions { display: flex; flex-direction: column; gap: 12px; height: 100%; min-height: 0; min-width: 0; }
  .head { display: flex; align-items: center; gap: 8px; min-height: 30px; min-width: 0; }
  .spacer { flex: 1; min-width: 0; }
  .small { font-size: 12px; }
  .mono { font-family: var(--mono); font-size: 11px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; user-select: text; }
  .filters { display: flex; gap: 8px; align-items: center; min-width: 0; }
  .chips { display: flex; gap: 6px; flex: 1; min-width: 0; overflow-x: auto; scrollbar-width: none; }
  .chip { border-radius: 999px; padding: 3px 10px; font-size: 11.5px; background: var(--smoke); white-space: nowrap; flex: none; }
  .chip.on { background: var(--iris); color: var(--on-iris); }
  .segment { display: flex; gap: 2px; padding: 2px; border-radius: 9px; background: var(--field); flex: none; }
  .segment button { background: none; border: none; color: var(--text3); padding: 3px 10px; border-radius: 7px; font-size: 11.5px; }
  .segment button.on, .segment button:hover { color: var(--paper); background: var(--smoke); }
  .body { flex: 1; min-height: 0; display: flex; }
  .body.split { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.1fr); gap: 16px; }
  .list { overflow-y: auto; min-height: 0; flex: 1; display: flex; flex-direction: column; gap: 2px; }
  .side { min-height: 0; min-width: 0; padding-left: 16px; border-left: 1px solid var(--line); display: flex; flex-direction: column; }
  .row { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border: none; background: none; border-radius: 10px; text-align: left; min-width: 0; }
  .row:hover, .row.on { background: var(--smoke); }
  .row .chevron { opacity: 0; }
  .row:hover .chevron { opacity: 1; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }
  .name { font-size: 13.5px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .meta { font-size: 11.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-variant-numeric: tabular-nums; }
  .empty { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; padding-top: 8px; }
  .empty strong { font-size: 15px; }
</style>
