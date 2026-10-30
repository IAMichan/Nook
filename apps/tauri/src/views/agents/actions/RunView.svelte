<script lang="ts">
  // One workflow run (`ActionsRunDetailView` on the Mac): its state and clock, what started it, and its jobs. A job
  // opens its steps and log in place through `CheckLog`, the same view a pull request's check opens. A run that still
  // changes is read again every five seconds. Re-running and cancelling only happen after a click, and are written to
  // the action log.
  import { untrack } from "svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import {
    actionsApi, eventName, isLive, jobCheck, outcomeName, runClock,
    type RunAction, type RunDetail, type RunJob, type WorkflowRun,
  } from "../../../lib/actions";
  import { tr } from "../../../lib/i18n.svelte";
  import type { PullRequestCheck } from "../../../lib/pulls";
  import CheckLog from "../pulls/CheckLog.svelte";
  import { ago } from "../time";
  import RunMark from "./RunMark.svelte";

  let {
    repo, account, run: listed, narrow = false, onclose, onchanged,
  }: { repo: string; account: string | null; run: WorkflowRun; narrow?: boolean; onclose: () => void; onchanged: () => void } = $props();

  let detail = $state<RunDetail | null>(null);
  let error = $state<string | null>(null);
  let busy = $state<RunAction | null>(null);
  let actionError = $state<string | null>(null);
  /// The job whose steps and log are shown in place of the job list; kept by id across a refresh.
  let openJob = $state<number | null>(null);
  let now = $state(Date.now());
  // Bumped to read the run again at once (after an action).
  let reload = $state(0);

  // The list hands over a fresh copy of the run on each refresh; only another run reads again.
  const runId = $derived(listed.id);
  // What the list showed, until the run itself is read.
  const run = $derived(detail?.run ?? listed);
  const live = $derived(isLive(run));
  const job = $derived(detail?.jobs.find((j) => j.id === openJob) ?? null);
  const check = $derived<PullRequestCheck | null>(job ? jobCheck(job) : null);
  const clock = $derived(runClock(run, now));

  $effect(() => {
    void reload;
    const id = runId;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const read = async () => {
      try {
        const fresh = await actionsApi.run(untrack(() => detail?.account ?? account), repo, id);
        if (cancelled) return;
        detail = fresh;
        error = null;
        if (!isLive(fresh.run)) return;
      } catch (e) {
        if (cancelled) return;
        error = String(e);
      }
      timer = setTimeout(read, 5000);
    };
    read();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  });

  // The clock of a running run counts up each second.
  $effect(() => {
    if (!live) return;
    const tick = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(tick);
  });

  async function act(action: RunAction) {
    if (action === "cancel" && !confirm(tr(`Run #${run.number} van ${run.workflow} annuleren?`, `Cancel run #${run.number} of ${run.workflow}?`))) return;
    busy = action;
    actionError = null;
    try {
      await actionsApi.act(detail?.account ?? account, repo, run.id, action);
      reload++;
      onchanged();
    } catch (e) {
      actionError = String(e);
    } finally {
      busy = null;
    }
  }

  function open(url: string | null) {
    if (url && /^https:\/\//.test(url)) openUrl(url);
  }

  const jobClock = (j: RunJob) => (j.outcome === "skipped" ? null : runClock(j, now));
</script>

<div class="run">
  {#if job && check}
    <CheckLog accountId={detail?.account ?? account ?? ""} {repo} {check} onback={() => (openJob = null)} />
  {:else}
    <div class="head">
      <button class="ghost icon" title={narrow ? tr("Terug", "Back") : tr("Sluiten", "Close")} aria-label={narrow ? tr("Terug", "Back") : tr("Sluiten", "Close")} onclick={onclose}>{narrow ? "‹" : "✕"}</button>
      <RunMark outcome={run.outcome} running={run.running} />
      <span class="state {run.outcome}">{outcomeName(run)}{#if clock}<span class="mono"> · {clock}</span>{/if}</span>
      <span class="spacer"></span>
      {#if run.url}<button class="ghost" onclick={() => open(run.url)}>{tr("Open op GitHub", "Open on GitHub")} ↗</button>{/if}
    </div>

    <div class="summary">
      <span class="faint small">{run.workflow} #{run.number}{#if run.attempt > 1} · {tr("poging", "attempt")} {run.attempt}{/if}</span>
      <strong class="title">{run.title}</strong>
      <div class="meta faint">
        {#if run.branch}<span class="mono branch" title={run.branch}>⑂ {run.branch}</span>·{/if}
        {#if run.sha}<span class="mono">{run.sha.slice(0, 7)}</span>·{/if}
        <span>{eventName(run.event)}</span>
        {#if run.actor}·<span>@{run.actor}</span>{/if}
        {#if run.created}·<span>{ago(run.created, now)}</span>{/if}
      </div>
    </div>

    <div class="buttons">
      {#if live}
        <button disabled={busy !== null} onclick={() => act("cancel")}>{busy === "cancel" ? tr("Annuleren…", "Cancelling…") : tr("Annuleren", "Cancel")}</button>
      {:else}
        {#if run.outcome === "failing"}
          <button class="primary" disabled={busy !== null} onclick={() => act("rerunFailed")}>{tr("Mislukte jobs opnieuw", "Re-run failed jobs")}</button>
        {/if}
        <button disabled={busy !== null} onclick={() => act("rerun")}>{busy === "rerun" ? tr("Bezig…", "Starting…") : tr("Opnieuw draaien", "Re-run")}</button>
      {/if}
    </div>
    {#if actionError}<p class="err">{actionError}</p>{/if}

    <div class="section">
      <div class="label faint">{tr("Jobs", "Jobs")}</div>
      {#if error && !detail}
        <p class="err">{error}</p>
      {:else if !detail}
        <span class="faint small">{tr("Jobs laden…", "Loading jobs…")}</span>
      {:else}
        {#each detail.jobs as j (j.id)}
          <!-- A job opens its steps and log here; without a page link it has nothing to read. -->
          <button class="line" disabled={!j.url} onclick={() => (openJob = j.id)}>
            <RunMark outcome={j.outcome} running={j.running} />
            <span class="name" class:bad={j.outcome === "failing"}>{j.name}</span>
            <span class="spacer"></span>
            {#if jobClock(j)}<span class="clock">{jobClock(j)}</span>{/if}
            <span class="faint small">›</span>
          </button>
        {:else}
          <span class="faint small">{live ? tr("Nog geen jobs gestart.", "No jobs started yet.") : tr("Deze run heeft geen jobs.", "This run has no jobs.")}</span>
        {/each}
        {#if error}<p class="err">{error}</p>{/if}
      {/if}
    </div>
  {/if}
</div>

<style>
  .run { display: flex; flex-direction: column; gap: 12px; height: 100%; min-height: 0; min-width: 0; overflow-y: auto; }
  .head { display: flex; align-items: center; gap: 6px; min-height: 30px; }
  .icon { width: 28px; height: 28px; padding: 0; font-size: 16px; }
  .spacer { flex: 1; min-width: 0; }
  .small { font-size: 11.5px; }
  .mono { font-family: var(--mono); font-size: 11.5px; font-variant-numeric: tabular-nums; }
  .state { font-weight: 600; font-size: 12.5px; white-space: nowrap; }
  .state.passing { color: var(--mint); }
  .state.failing { color: var(--coral); }
  .state.pending { color: var(--amber); }
  .state.skipped, .state.cancelled { color: var(--text2); }
  .summary { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .title { font-size: 15px; user-select: text; }
  .meta { display: flex; align-items: center; gap: 6px; font-size: 11.5px; min-width: 0; flex-wrap: wrap; }
  .branch { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 220px; }
  .buttons { display: flex; gap: 6px; flex-wrap: wrap; }
  .section { display: flex; flex-direction: column; gap: 4px; }
  .label { font-size: 11.5px; font-weight: 600; }
  .line { display: flex; align-items: center; gap: 8px; padding: 5px 6px; background: none; border: none; text-align: left; border-radius: 7px; min-width: 0; font-size: 12.5px; }
  button.line:hover:not(:disabled) { background: var(--smoke); }
  .line:disabled { opacity: 1; cursor: default; }
  .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .clock { font-family: var(--mono); font-size: 10.5px; color: var(--text3); font-variant-numeric: tabular-nums; flex: none; }
  .bad { color: var(--coral); }
  .err { color: var(--coral); font-size: 12px; margin: 0; user-select: text; }
</style>
