<script lang="ts">
  // One CI check read inside Nook (`CICheckLogView` on the Mac): the steps of its GitHub Actions job and the end of its
  // log. A job that still runs is read again every few seconds until GitHub has its log.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { jobId, pullsApi, type CheckOutcome, type CiLog, type PullRequestCheck } from "../../../lib/pulls";

  let { accountId, repo, check, onback }: { accountId: string; repo: string; check: PullRequestCheck; onback: () => void } = $props();

  let log = $state<CiLog | null>(null);
  let error = $state<string | null>(null);
  let copied = $state(false);
  let pre = $state<HTMLPreElement | null>(null);
  // A refresh of the pull request hands over a new copy of the same check: only another job reads again.
  const job = $derived(jobId(check.url));

  $effect(() => {
    const id = job;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    log = null;
    error = null;
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
    if (pre && log?.text) pre.scrollTop = pre.scrollHeight;
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
          <div class="step">{@render mark(step.outcome)}<span class="muted small name">{step.name}</span></div>
        {/each}
      </div>
    {/if}
    {#if log.text !== null}
      {#if log.omittedLines > 0}<span class="faint small">{log.omittedLines} eerdere regels weggelaten</span>{/if}
      <pre class="log" bind:this={pre}>{log.text}</pre>
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
  .steps { display: flex; flex-direction: column; gap: 3px; }
  .step { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .mark { width: 16px; display: grid; place-items: center; flex: none; }
  .good { color: var(--mint); }
  .bad { color: var(--coral); }
  .log { margin: 0; flex: 1; min-height: 160px; font-family: var(--mono); font-size: 11px; line-height: 1.45; background: var(--field); border: 1px solid var(--line2); border-radius: 10px; padding: 8px 10px; overflow: auto; white-space: pre; user-select: text; }
  .err { color: var(--coral); font-size: 12px; user-select: text; }
</style>
