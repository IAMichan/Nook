<script lang="ts">
  // One CI check read inside Nook (`CICheckLogView` on the Mac): the steps of its GitHub Actions job and the end of its
  // log. A job that still runs is followed live: the running step counts up, the bar fills as steps finish, and the log
  // takes the steps' place as soon as GitHub has it (GitHub hands out a job's log only once the job is done).
  import { openUrl } from "@tauri-apps/plugin-opener";
  import {
    ciClock, ciElapsed, ciLines, ciProblems, ciStatusLine, jobId, pullsApi,
    type CheckOutcome, type CiLog, type CiStep, type PullRequestCheck,
  } from "../../../lib/pulls";

  let { accountId, repo, check, onback }: { accountId: string; repo: string; check: PullRequestCheck; onback: () => void } = $props();

  let log = $state<CiLog | null>(null);
  let error = $state<string | null>(null);
  let copied = $state(false);
  let pre = $state<HTMLPreElement | null>(null);
  let stepList = $state<HTMLDivElement | null>(null);
  let now = $state(Date.now());
  // Null until the reader picks: a log with errors opens on them, one without opens whole.
  let fullLog = $state<boolean | null>(null);
  // The steps above a log, folded away by default so the log has the room.
  let showSteps = $state(false);
  const lines = $derived(log?.text ? ciLines(log.text) : []);
  const problems = $derived(ciProblems(lines));
  const problemCount = $derived(problems.filter((l) => l.kind !== "group").length);
  const onlyProblems = $derived(problemCount > 0 && !fullLog);
  const shown = $derived(onlyProblems ? problems : lines);
  // A refresh of the pull request hands over a new copy of the same check: only another job reads again.
  const job = $derived(jobId(check.url));
  // What the job says once it is read, else what the check said: a check read a while ago may still say "running".
  const outcome = $derived<CheckOutcome>(
    log?.finished && check.outcome === "pending" ? (log.steps.some((s) => s.outcome === "failing") ? "failing" : "passing") : check.outcome,
  );
  const runningStep = $derived(log?.steps.find((s) => s.running) ?? null);
  const running = $derived(outcome === "pending" && (runningStep !== null || check.running));
  const doneSteps = $derived(log?.steps.filter((s) => s.outcome !== "pending").length ?? 0);
  const failedStep = $derived(log?.steps.find((s) => s.outcome === "failing") ?? null);
  const progress = $derived(running && runningStep && log ? `stap ${log.steps.indexOf(runningStep) + 1} van ${log.steps.length}` : null);
  const status = $derived(
    ciStatusLine(
      { ...check, outcome, running, started: log?.started ?? check.started, finished: log?.finished ?? check.finished },
      now,
      progress,
    ),
  );

  $effect(() => {
    const id = job;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    log = null;
    error = null;
    fullLog = null;
    showSteps = false;
    if (id === null) return;
    const read = async () => {
      try {
        const fresh = await pullsApi.ciLog(accountId, repo, id);
        if (cancelled) return;
        log = fresh;
        error = null;
        if (fresh.text !== null) return;
      } catch (e) {
        if (cancelled) return;
        if (!log) error = String(e);
      }
      timer = setTimeout(read, 3000);
    };
    read();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  });

  // The running clocks count up each second.
  $effect(() => {
    if (!running) return;
    const tick = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(tick);
  });

  // A failure is at the end of a log.
  $effect(() => {
    if (pre && shown.length) pre.scrollTop = pre.scrollHeight;
  });

  // The running step stays in view.
  $effect(() => {
    const number = runningStep?.number;
    if (!stepList || number === undefined) return;
    stepList.querySelector(`[data-step="${number}"]`)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  });

  async function copy() {
    if (!log?.text) return;
    try {
      await navigator.clipboard.writeText(log.text);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      // Selecting the text still works.
    }
  }

  function open() {
    if (check.url && /^https:\/\//.test(check.url)) openUrl(check.url);
  }

  function stepClock(step: CiStep): string | null {
    if (step.outcome === "skipped") return null;
    const seconds = ciElapsed(step.started, step.finished, now);
    return seconds === null ? null : ciClock(seconds);
  }
</script>

<div class="checklog">
  <div class="checkhead">
    <button class="ghost icon" title="Terug" aria-label="Terug" onclick={onback}>‹</button>
    {@render mark(outcome, running)}
    <div class="title">
      <strong class="name">{check.name}</strong>
      <span class="small status" class:bad={outcome === "failing"}>{status}</span>
    </div>
    <span class="spacer"></span>
    {#if log?.text}<button class="ghost" onclick={copy}>{copied ? "Gekopieerd" : "Kopieer log"}</button>{/if}
    {#if check.url}<button class="ghost" title="Open de pagina van de check" onclick={open}>Open op GitHub ↗</button>{/if}
  </div>
  {#if running && log?.steps.length}
    <div class="bar"><span style:width="{Math.max(2, (doneSteps / log.steps.length) * 100)}%"></span></div>
  {/if}
  {#if job === null}
    <span class="faint small">Deze check komt van een andere app; de details staan op zijn eigen pagina.</span>
  {:else if error}
    <span class="err">{error}</span>
  {:else if log}
    {#if log.text === null}
      <div class="steps timeline" bind:this={stepList}>
        {#each log.steps as step (step.number)}{@render stepRow(step)}{/each}
      </div>
      <div class="live">
        <span class="dot working live-dot"></span>
        <div class="live-text">
          <strong class="small">Live gevolgd</strong>
          <span class="faint small">GitHub geeft het log pas vrij als de job klaar is; dan staat het hier meteen.</span>
        </div>
        {#if check.url}<button class="ghost" onclick={open}>Volg op GitHub</button>{/if}
      </div>
    {:else}
      {#if log.steps.length}
        <button class="fold" onclick={() => (showSteps = !showSteps)}>
          <span class="chev" class:open={showSteps}>›</span>
          {log.steps.length} stappen
          {#if failedStep}<span>·</span><span class="bad ellipsis">mislukt bij {failedStep.name}</span>{/if}
        </button>
        {#if showSteps}
          <div class="steps folded">
            {#each log.steps as step (step.number)}{@render stepRow(step)}{/each}
          </div>
        {/if}
      {/if}
      {#if problemCount > 0}
        <div class="chips">
          <button class="chip" class:on={onlyProblems} onclick={() => (fullLog = false)}>Fouten en waarschuwingen <span class="faint">{problemCount}</span></button>
          <button class="chip" class:on={!onlyProblems} onclick={() => (fullLog = true)}>Volledig log</button>
        </div>
      {/if}
      {#if log.omittedLines > 0 && !onlyProblems}<span class="faint small">{log.omittedLines} eerdere regels weggelaten</span>{/if}
      <pre class="log" bind:this={pre}>{#each shown as line, i (i)}<span class={line.kind}>{line.kind === "group" ? "▸ " : ""}{line.text}</span>{"\n"}{/each}</pre>
    {/if}
  {:else}
    <span class="faint small">Log laden…</span>
  {/if}
</div>

{#snippet stepRow(step: CiStep)}
  <div class="step" data-step={step.number} class:running={step.running} class:skipped={step.outcome === "skipped"}
    class:waiting={step.outcome === "pending" && !step.running} class:failed={step.outcome === "failing"}>
    {@render mark(step.outcome, step.running)}
    <span class="small name">{step.name}</span>
    <span class="spacer"></span>
    {#if stepClock(step)}<span class="clock">{stepClock(step)}</span>{/if}
  </div>
{/snippet}

{#snippet mark(outcome: CheckOutcome, running: boolean)}
  <span class="mark">
    {#if outcome === "passing"}<span class="good">✓</span>{:else if outcome === "failing"}<span class="bad">✕</span>{:else if outcome === "pending" && running}<span class="spin"></span>{:else if outcome === "pending"}<span class="dot waiting"></span>{:else}<span class="faint">–</span>{/if}
  </span>
{/snippet}

<style>
  .checklog { display: flex; flex-direction: column; gap: 8px; min-height: 0; flex: 1; }
  .checkhead { display: flex; align-items: center; gap: 6px; min-height: 30px; }
  .title { display: flex; flex-direction: column; min-width: 0; gap: 1px; }
  .status { color: var(--text3); font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .icon { width: 28px; height: 28px; padding: 0; font-size: 16px; }
  .spacer { flex: 1; min-width: 0; }
  .small { font-size: 11.5px; }
  .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ellipsis { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .bar { height: 3px; border-radius: 999px; background: var(--smoke); overflow: hidden; flex: none; }
  .bar span { display: block; height: 100%; border-radius: 999px; background: var(--paper); transition: width 0.3s ease; }
  .steps { display: flex; flex-direction: column; gap: 2px; overflow-y: auto; }
  .steps.timeline { flex: 1; min-height: 0; }
  .steps.folded { max-height: 140px; flex: none; }
  .step { display: flex; align-items: center; gap: 8px; min-width: 0; padding: 4px 6px; border-radius: 6px; color: var(--text2); }
  .step.running { background: var(--smoke); color: var(--paper); font-weight: 600; }
  .step.skipped, .step.waiting { color: var(--text3); }
  .step.failed { color: var(--coral); font-weight: 600; }
  .clock { font-family: var(--mono); font-size: 10.5px; color: var(--text3); font-variant-numeric: tabular-nums; flex: none; }
  .step.running .clock { color: var(--paper); }
  .live { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border-radius: 8px; background: var(--field); flex: none; }
  .live-dot { background: var(--mint); width: 6px; height: 6px; }
  .live-text { display: flex; flex-direction: column; gap: 1px; min-width: 0; flex: 1; }
  .fold { display: flex; align-items: center; gap: 4px; background: none; padding: 0; font-size: 12px; color: var(--text2); text-align: left; min-width: 0; }
  .chev { display: inline-block; width: 10px; transition: transform 0.2s ease; }
  .chev.open { transform: rotate(90deg); }
  .chips { display: flex; gap: 6px; }
  .chip { border-radius: 999px; padding: 3px 10px; font-size: 11.5px; background: var(--smoke); }
  .chip.on { background: var(--iris); color: var(--on-iris); }
  .log .group { font-weight: 600; color: var(--text2); }
  .log .command { color: var(--text3); }
  .log .error { color: var(--coral); }
  .log .warning { color: var(--amber); }
  .log .notice { color: var(--violet); }
  .mark { width: 16px; display: grid; place-items: center; flex: none; }
  .spin { width: 10px; height: 10px; border-radius: 50%; border: 1.5px dashed var(--paper); animation: spin 1.6s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .good { color: var(--mint); }
  .bad { color: var(--coral); }
  .log { margin: 0; flex: 1; min-height: 160px; font-family: var(--mono); font-size: 11px; line-height: 1.55; background: var(--field); border: 1px solid var(--line2); border-radius: 10px; padding: 10px 12px; overflow-x: hidden; overflow-y: auto; white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; }
  .err { color: var(--coral); font-size: 12px; user-select: text; }
</style>
