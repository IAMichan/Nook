<script lang="ts">
  // One CI check read inside Nook (`CICheckLogView` on the Mac): the steps of its GitHub Actions job and the end of its
  // log. A job that still runs is read again every few seconds until GitHub has its log.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { ciLines, ciProblems, jobId, pullsApi, type CheckOutcome, type CiLog, type PullRequestCheck } from "../../../lib/pulls";

  let { accountId, repo, check, onback }: { accountId: string; repo: string; check: PullRequestCheck; onback: () => void } = $props();

  let log = $state<CiLog | null>(null);
  let error = $state<string | null>(null);
  let copied = $state(false);
  let pre = $state<HTMLPreElement | null>(null);
  // Null until the reader picks: a log with errors opens on them, one without opens whole.
  let fullLog = $state<boolean | null>(null);
  const lines = $derived(log?.text ? ciLines(log.text) : []);
  const problems = $derived(ciProblems(lines));
  const problemCount = $derived(problems.filter((l) => l.kind !== "group").length);
  const onlyProblems = $derived(problemCount > 0 && !fullLog);
  const shown = $derived(onlyProblems ? problems : lines);
  // A refresh of the pull request hands over a new copy of the same check: only another job reads again.
  const job = $derived(jobId(check.url));

  $effect(() => {
    const id = job;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    log = null;
    error = null;
    fullLog = null;
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
      timer = setTimeout(read, 5000);
    };
    read();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  });

  // A failure is at the end of a log.
  $effect(() => {
    if (pre && shown.length) pre.scrollTop = pre.scrollHeight;
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
</script>

<div class="checklog">
  <div class="checkhead">
    <button class="ghost icon" title="Terug" aria-label="Terug" onclick={onback}>‹</button>
    {@render mark(check.outcome)}
    <strong class="name">{check.name}</strong>
    <span class="spacer"></span>
    {#if log?.text}<button class="ghost" onclick={copy}>{copied ? "Gekopieerd" : "Kopieer log"}</button>{/if}
    {#if check.url}<button class="ghost" title="Open de pagina van de check" onclick={open}>Open op GitHub ↗</button>{/if}
  </div>
  {#if job === null}
    <span class="faint small">Deze check komt van een andere app; de details staan op zijn eigen pagina.</span>
  {:else if error}
    <span class="err">{error}</span>
  {:else if log}
    {#if log.steps.length}
      <div class="steps">
        {#each log.steps as step (step.number)}
          <div class="step" class:skipped={step.outcome === "skipped"} class:failed={step.outcome === "failing"}>{@render mark(step.outcome)}<span class="small name">{step.name}</span></div>
        {/each}
      </div>
    {/if}
    {#if log.text !== null}
      {#if problemCount > 0}
        <div class="chips">
          <button class="chip" class:on={onlyProblems} onclick={() => (fullLog = false)}>Fouten en waarschuwingen <span class="faint">{problemCount}</span></button>
          <button class="chip" class:on={!onlyProblems} onclick={() => (fullLog = true)}>Volledig log</button>
        </div>
      {/if}
      {#if log.omittedLines > 0 && !onlyProblems}<span class="faint small">{log.omittedLines} eerdere regels weggelaten</span>{/if}
      <pre class="log" bind:this={pre}>{#each shown as line, i (i)}<span class={line.kind}>{line.kind === "group" ? "▸ " : ""}{line.text}</span>{"\n"}{/each}</pre>
    {:else}
      <span class="faint small">De job loopt nog; het log verschijnt zodra hij klaar is. De stappen verversen vanzelf.</span>
    {/if}
  {:else}
    <span class="faint small">Log laden…</span>
  {/if}
</div>

{#snippet mark(outcome: CheckOutcome)}
  <span class="mark">
    {#if outcome === "passing"}<span class="good">✓</span>{:else if outcome === "failing"}<span class="bad">✕</span>{:else if outcome === "pending"}<span class="dot waiting"></span>{:else}<span class="faint">–</span>{/if}
  </span>
{/snippet}

<style>
  .checklog { display: flex; flex-direction: column; gap: 8px; min-height: 0; flex: 1; }
  .checkhead { display: flex; align-items: center; gap: 6px; min-height: 30px; }
  .icon { width: 28px; height: 28px; padding: 0; font-size: 16px; }
  .spacer { flex: 1; min-width: 0; }
  .small { font-size: 11.5px; }
  .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .steps { display: flex; flex-direction: column; gap: 3px; max-height: 112px; overflow-y: auto; flex: none; }
  .step { color: var(--text2); }
  .step.skipped { color: var(--text3); }
  .step.failed { color: var(--coral); font-weight: 600; }
  .chips { display: flex; gap: 6px; }
  .chip { border-radius: 999px; padding: 3px 10px; font-size: 11.5px; background: var(--smoke); }
  .chip.on { background: var(--iris); color: var(--on-iris); }
  .log .group { font-weight: 600; color: var(--text2); }
  .log .command { color: var(--text3); }
  .log .error { color: var(--coral); }
  .log .warning { color: var(--amber); }
  .log .notice { color: var(--violet); }
  .step { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .mark { width: 16px; display: grid; place-items: center; flex: none; }
  .good { color: var(--mint); }
  .bad { color: var(--coral); }
  .log { margin: 0; flex: 1; min-height: 160px; font-family: var(--mono); font-size: 11px; line-height: 1.45; background: var(--field); border: 1px solid var(--line2); border-radius: 10px; padding: 8px 10px; overflow-x: hidden; overflow-y: auto; white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; }
  .err { color: var(--coral); font-size: 12px; user-select: text; }
</style>
