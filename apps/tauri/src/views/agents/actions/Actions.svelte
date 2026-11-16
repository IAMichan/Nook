<script lang="ts">
  // Agents › Actions (`ActionsPanel` on the Mac): the GitHub Actions runs of one repository, so a CI run or a promote
  // can be followed without a pull request in between. The repositories sit on top as tabs (each marked while something
  // runs or a workflow fails, ⇧⌘[ / ⇧⌘] to step through them, "+" to open another), narrow the runs to a workflow
  // or to the running or failed ones, and open a run beside the list (in its place when the window is narrow) to see
  // its jobs, re-run or cancel it, and read a job's log. "Run workflow" starts one that has a workflow_dispatch trigger.
  // The list is read again every ten seconds while something in it runs, and every minute otherwise. Switching a filter
  // or a tab shows what is already known at once (the matching runs of the list read before, a tab's last read) while
  // GitHub's answer is on its way.
  import { untrack } from "svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import {
    actionsApi, candidateRepos, eventName, filterRuns, isLive, latestPerWorkflow, neighborTab, openTab, parseRepo, repoStatus,
    runClock, statusFilterName, type ActionsRepo, type Dispatched, type RepoStatus, type RunStatusFilter, type Workflow,
    type WorkflowRun,
  } from "../../../lib/actions";
  import { api } from "../../../lib/api";
  import { tr } from "../../../lib/i18n.svelte";
  import RunSkeleton from "./RunSkeleton.svelte";
  import { pullRequests } from "../../../lib/pulls.svelte";
  import { ago } from "../time";
  import RepoPicker from "./RepoPicker.svelte";
  import RepoTabs from "./RepoTabs.svelte";
  import RunMark from "./RunMark.svelte";
  import RunView from "./RunView.svelte";
  import DispatchSheet from "./DispatchSheet.svelte";

  const REPO_KEY = "agents.actions.repo";
  const TYPED_KEY = "agents.actions.typed";
  const TYPED_LIMIT = 10;
  const TABS_KEY = "agents.actions.tabs";
  /// The other tabs are read in the background at most this often, so each shows how it stands.
  const PEEK_MS = 120_000;
  const STATUSES: RunStatusFilter[] = ["all", "running", "failed"];
  const ALL_RUNS = runsFilterKey(null, "all");

  let pushed = $state<ActionsRepo[]>([]);
  let available = $state(true);
  let reposLoaded = $state(false);
  let typed = $state<string[]>(readTyped());
  let repo = $state<string | null>(read(REPO_KEY));
  let tabs = $state<string[]>(readTabs());
  /// How each repository read so far stands, by its lowercased name, for its tab.
  let statuses = $state<Record<string, RepoStatus | null>>({});
  let workflows = $state<Workflow[]>([]);
  let workflow = $state<number | null>(null);
  let status = $state<RunStatusFilter>("all");
  let runs = $state<WorkflowRun[]>([]);
  /// The filter `runs` was read for ("workflow|status"); the list shows the runs that match the current one meanwhile.
  let runsKey = $state(ALL_RUNS);
  /// The last list of all runs and the workflows of each repository read so far, by its lowercased name, so a tab
  /// opens with them at once.
  const known = new Map<string, { runs: WorkflowRun[]; account: string; workflows?: Workflow[] }>();
  let dispatching = $state(false);
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
  // The runs that match the filter, also while the list read for the one before is still shown.
  const shown = $derived(filterRuns(runs, workflow, status));
  const stale = $derived(runsKey !== runsFilterKey(workflow, status));
  // The run beside the list keeps up with the list's copy, so its row and its header agree.
  const openedRun = $derived(opened ? (runs.find((r) => r.id === opened!.id) ?? opened) : null);
  // The mark on each workflow's chip: its newest run, from the list of all workflows.
  const newest = $derived(runsKey === ALL_RUNS ? latestPerWorkflow(runs) : new Map<number, WorkflowRun>());

  function runsFilterKey(flow: number | null, filter: RunStatusFilter) {
    return `${flow ?? ""}|${filter}`;
  }

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

  // Before there were tabs: the repository you had open and the ones you typed in.
  function readTabs(): string[] {
    try {
      const list = JSON.parse(localStorage.getItem(TABS_KEY) ?? "null");
      if (Array.isArray(list)) return list.filter((x): x is string => typeof x === "string" && parseRepo(x) === x);
    } catch {
      // Falls back to what was remembered before.
    }
    return [read(REPO_KEY), ...readTyped()].filter((x): x is string => !!x).reduceRight<string[]>((list, name) => openTab(name, list), []);
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
    setTabs(openTab(name, tabs));
    if (name === repo) return;
    repo = name;
    write(REPO_KEY, name);
  }

  function setTabs(list: string[]) {
    tabs = list;
    write(TABS_KEY, JSON.stringify(list));
  }

  /// Takes a repository off the tab bar; closing the open one opens the tab next to it.
  function closeTab(name: string) {
    const index = tabs.findIndex((t) => t.toLowerCase() === name.toLowerCase());
    if (index < 0) return;
    const rest = tabs.filter((_, i) => i !== index);
    setTabs(rest);
    if (name.toLowerCase() === (repo ?? "").toLowerCase() && rest.length) pick(rest[Math.min(index, rest.length - 1)]);
  }

  // ⇧⌘[ and ⇧⌘] (⇧Ctrl on Windows and Linux) go to the tab on the left or right, as on the Mac.
  function keys(e: KeyboardEvent) {
    if (!(e.metaKey || e.ctrlKey) || !e.shiftKey || (e.code !== "BracketLeft" && e.code !== "BracketRight")) return;
    const next = neighborTab(tabs, repo, e.code === "BracketLeft" ? -1 : 1);
    if (!next) return;
    e.preventDefault();
    pick(next);
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
    if (!repo && repos.length) pick(repos[0].name);
  });

  // Another repository: its own workflows, the filters back to all, the run closed.
  $effect(() => {
    const name = repo;
    const last = name ? known.get(name.toLowerCase()) : undefined;
    workflows = last?.workflows ?? [];
    workflow = null;
    opened = null;
    runs = last?.runs ?? [];
    runsKey = ALL_RUNS;
    loaded = !!last;
    dispatching = false;
    // Read without tracking: the picker's list grows while it loads, which is no reason to start over.
    account = last?.account ?? untrack(() => repos.find((r) => r.name === name)?.account ?? null);
    if (!name) return;
    let cancelled = false;
    actionsApi
      .workflows(untrack(() => account), name)
      .then((list) => {
        if (cancelled) return;
        workflows = list;
        const entry = known.get(name.toLowerCase());
        if (entry) entry.workflows = list;
      })
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
          runsKey = runsFilterKey(flow, filter);
          account = fresh.account;
          if (flow === null && filter === "all") remember(name, fresh.runs, fresh.account);
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

  // The other tabs, read in the background one after the other, so each says how it stands. A failure only leaves that
  // tab without a mark.
  const peekedAt = new Map<string, number>();
  $effect(() => {
    const others = tabs.filter((t) => t.toLowerCase() !== (repo ?? "").toLowerCase());
    if (!others.length || notConnected) return;
    let cancelled = false;
    const peek = async () => {
      for (const name of others) {
        if (cancelled || document.hidden) break;
        const key = name.toLowerCase();
        if (Date.now() - (peekedAt.get(key) ?? 0) < PEEK_MS) continue;
        peekedAt.set(key, Date.now());
        const owner = untrack(() => repos.find((r) => r.name.toLowerCase() === key)?.account ?? null);
        try {
          const fresh = await actionsApi.runs(owner, name, null, "all");
          if (!cancelled) remember(name, fresh.runs, fresh.account);
        } catch {
          // Only the tab's mark; opening the tab says what went wrong.
        }
      }
    };
    peek();
    const timer = setInterval(peek, PEEK_MS);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  });

  // The clocks of running runs count up each second; the relative times move on once a minute.
  $effect(() => {
    const tick = setInterval(() => (now = Date.now()), anyLive ? 1000 : 60_000);
    return () => clearInterval(tick);
  });

  /// A repository's latest list of all runs: its tab's mark, and what the tab shows at once when it opens.
  function remember(name: string, list: WorkflowRun[], reader: string) {
    const key = name.toLowerCase();
    statuses[key] = repoStatus(list);
    known.set(key, { runs: list, account: reader, workflows: known.get(key)?.workflows });
  }

  /// A workflow was started: the list is read again, and the new run opens when GitHub said which one it is. Without
  /// its id, the list is read once more a moment later, by when GitHub lists the run.
  function dispatched(result: Dispatched, flow: { id: number; name: string; branch: string }) {
    dispatching = false;
    account = result.account;
    reload++;
    if (result.run === null) {
      setTimeout(() => reload++, 2_000);
      return;
    }
    opened = {
      id: result.run, workflowId: flow.id, workflow: flow.name, title: flow.name, number: 0, attempt: 1, branch: flow.branch, sha: "",
      event: "workflow_dispatch", actor: "", status: "queued", conclusion: null, outcome: "pending", running: false,
      created: new Date().toISOString(), started: null, finished: null, url: null, path: "",
    };
  }

  function openSettings() {
    write("settings.section", "accounts");
    api.showMain("settings");
  }

  function open(url: string) {
    if (/^https:\/\//.test(url)) openUrl(url);
  }

  const notConnected = $derived(reposLoaded && !available && !pullRequests.accounts.length);
</script>

<svelte:window onkeydown={keys} />

<div class="actions" bind:clientWidth={width}>
  {#if openedRun && !wide}
    {#key openedRun.id}
      <RunView repo={repo ?? ""} {account} run={openedRun} narrow onclose={() => (opened = null)} onchanged={() => reload++} />
    {/key}
  {:else}
    <div class="head">
      <strong>Actions</strong>
      {#if !tabs.length}<RepoPicker {repos} value={repo} onpick={pick} />{/if}
      <span class="spacer"></span>
      <!-- A first read has the list's skeleton; this only marks a refresh. -->
      {#if loading && loaded}<span class="faint small">{tr("Bezig…", "Loading…")}</span>{/if}
      <button class="ghost" title={tr("Vernieuwen", "Refresh")} disabled={!repo || loading} onclick={() => reload++}>{tr("Vernieuwen", "Refresh")}</button>
      {#if repo && !notConnected}<button title={tr("Start een workflow die met de hand kan starten", "Start a workflow that can be run by hand")} onclick={() => (dispatching = true)}>{tr("Workflow starten", "Run workflow")}</button>{/if}
      {#if repo}<button class="ghost" title={tr("Open de Actions van deze repository op GitHub", "Open this repository's Actions on GitHub")} onclick={() => open(`https://github.com/${repo}/actions`)}>{tr("Open op GitHub", "Open on GitHub")} ↗</button>{/if}
    </div>

    {#if tabs.length && !notConnected}
      <div class="repos">
        <RepoTabs {tabs} value={repo} {statuses} onpick={pick} onclose={closeTab} />
        <RepoPicker {repos} value={repo} onpick={pick} compact />
      </div>
    {/if}

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
            {@const last = newest.get(w.id)}
            <button class="chip" class:on={workflow === w.id} title={w.path} onclick={() => (workflow = w.id)}>
              {#if last && (last.outcome === "failing" || last.outcome === "pending")}<RunMark outcome={last.outcome} running={last.running} />{/if}{w.name}
            </button>
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
          {:else if !loaded || (stale && !shown.length)}
            <RunSkeleton />
          {:else if !shown.length}
            {#if workflow !== null || status !== "all"}
              {@render empty(tr("Geen runs gevonden", "No runs found"), tr("Niets past bij dit filter.", "Nothing matches this filter."), [tr("Wis filter", "Clear filter"), () => ((workflow = null), (status = "all"))])}
            {:else}
              {@render empty(tr("Nog geen workflow-runs", "No workflow runs yet"), tr("Deze repository heeft nog niets gedraaid met GitHub Actions.", "Nothing has run with GitHub Actions in this repository yet."))}
            {/if}
          {:else}
            {#if error}<p class="err">{error}</p>{/if}
            {#each shown as run (run.id)}
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

{#if dispatching && repo}
  <DispatchSheet {repo} {account} selected={workflow} onclose={() => (dispatching = false)} ondispatched={dispatched} />
{/if}

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
  .repos { display: flex; align-items: center; gap: 4px; min-width: 0; padding-bottom: 8px; border-bottom: 1px solid var(--line); }
  .chip { display: inline-flex; align-items: center; gap: 2px; border-radius: 999px; padding: 3px 10px; font-size: 11.5px; background: var(--smoke); white-space: nowrap; flex: none; }
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
