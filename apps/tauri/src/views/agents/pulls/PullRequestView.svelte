<script lang="ts">
  // One pull request, read in full inside Nook (`PullRequestDetailView` on the Mac): the description, checks and
  // timeline, the commits, and every changed file with its diff. The bar at the bottom merges it with the account it
  // was listed under, only after you confirmed it in that same bar; the merge is written to the action log. A page read
  // before (or ahead, see `pullDetails`) shows at once and refreshes underneath.
  import { untrack } from "svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import type { PullRequestItem } from "../../../lib/connectors";
  import { renderMarkdown } from "../../../lib/markdown";
  import {
    activitySentence, chosenMethod, ciStatusLine, detailStateNames, diffLines, eventLabel, itemId, jobId, methodNames, noteText, pullsApi,
    type MergeMethod, type PullRequestCheck, type PullRequestDetail, type PullRequestEvent, type PullRequestFile, type ReviewEvent,
  } from "../../../lib/pulls";
  import { pullDetails, pullRequests } from "../../../lib/pulls.svelte";
  import { ago } from "../time";
  import { tr } from "../../../lib/i18n.svelte";
  import CheckLog from "./CheckLog.svelte";
  import PullGlyph from "./PullGlyph.svelte";

  let { accountId, item, onback }: { accountId: string; item: PullRequestItem; onback: () => void } = $props();

  type Tab = "conversation" | "commits" | "files";
  const METHOD_KEY = "agents.pr.mergeMethod";

  let detail = $state<PullRequestDetail | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let tab = $state<Tab>("conversation");
  let openFile = $state<string | null>(null);
  /// The check whose steps and log the conversation shows in its place; kept by name and link across a refresh.
  let openCheck = $state<PullRequestCheck | null>(null);
  let savedMethod = $state(readMethod());
  let confirming = $state(false);
  let merging = $state(false);
  let mergeError = $state<string | null>(null);
  let reviewing = $state(false);
  let reviewText = $state("");
  let reviewBusy = $state(false);
  let reviewNote = $state<{ ok: boolean; text: string } | null>(null);
  // The relative times in the conversation and the commits tick along, once a minute.
  let now = $state(Date.now());

  const method = $derived(chosenMethod(savedMethod, detail?.methods ?? []));
  const ready = $derived(!!detail && detail.canMerge && detail.mergeNote === null);
  const file = $derived(detail?.files.find((f) => f.path === openFile) ?? null);
  const shownCheck = $derived(openCheck && (detail?.checks.find((c) => c.name === openCheck!.name && c.url === openCheck!.url) ?? openCheck));
  const fileIndex = $derived(detail && file ? detail.files.indexOf(file) : -1);

  function readMethod(): string | null {
    try {
      return localStorage.getItem(METHOD_KEY);
    } catch {
      return null;
    }
  }

  function pick(m: MergeMethod) {
    savedMethod = m;
    try {
      localStorage.setItem(METHOD_KEY, m);
    } catch {
      // Only remembers the choice for next time.
    }
  }

  const load = () => read(false);

  /// `share`: the first look waits for a read ahead that is already running instead of starting another.
  async function read(share: boolean) {
    if (loading) return;
    loading = true;
    try {
      const fresh = await pullDetails.read(accountId, item.repo, item.number, share);
      detail = fresh;
      error = null;
      if (openFile && !fresh.files.some((f) => f.path === openFile)) openFile = null;
    } catch (e) {
      // A failed refresh keeps what was shown.
      if (detail) mergeError = String(e);
      else error = String(e);
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    let cancelled = false;
    let recheck: ReturnType<typeof setTimeout> | undefined;
    // Only a different pull request loads again; `load` reads `loading`, which must not re-run this effect.
    void [accountId, item.repo, item.number];
    const cached = untrack(() => pullDetails.get(accountId, item.repo, item.number));
    untrack(() => {
      detail = cached?.detail ?? null;
      error = null;
    });
    // Read in the last ten seconds: shown as it is, the next look is never far away.
    const first = cached && Date.now() - cached.at < 10_000 ? Promise.resolve() : untrack(() => read(true));
    first.then(() => {
      // GitHub works out mergeability after the first ask: look again once it has.
      if (!cancelled && detail?.isOpen && detail.mergeable === null) recheck = setTimeout(() => !cancelled && load(), 3000);
    });
    const timer = setInterval(() => (now = Date.now()), 60_000);
    // Something you cannot merge yourself (no rights, held back by reviews or checks) is looked at again every half
    // minute, so it shows as merged as soon as someone else does it.
    const watch = setInterval(() => {
      if (detail?.isOpen && !detail.canMerge && detail.state !== "draft") untrack(load);
    }, 30_000);
    return () => {
      clearInterval(watch);
      cancelled = true;
      clearTimeout(recheck);
      clearInterval(timer);
    };
  });

  /// Only https links from GitHub open, in the browser.
  function open(url: string | null | undefined) {
    if (url && /^https:\/\//.test(url)) openUrl(url);
  }

  function linkClick(e: MouseEvent) {
    const a = (e.target as HTMLElement).closest("a[data-external]") as HTMLAnchorElement | null;
    if (a) {
      e.preventDefault();
      open(a.href);
    }
  }

  const commitUrl = (sha: string) => (detail?.url ? `${detail.url}/commits/${sha}` : null);

  /// Only after the confirmation: merges the head that is shown.
  async function merge() {
    confirming = false;
    if (!detail || !detail.canMerge || merging) return;
    merging = true;
    mergeError = null;
    try {
      await pullsApi.merge(accountId, detail.repo, detail.number, method, detail.headSha);
      pullRequests.markStale();
      merging = false;
      await load();
      pullRequests.refresh(true);
    } catch (e) {
      mergeError = String(e);
      merging = false;
    }
  }

  /// Posts the review typed in the bar. A comment and a request for changes need text; an approval does not.
  async function sendReview(event: ReviewEvent) {
    if (!detail || reviewBusy) return;
    if (event !== "APPROVE" && !reviewText.trim()) {
      reviewNote = { ok: false, text: tr("Schrijf eerst een opmerking.", "Write a comment first.") };
      return;
    }
    reviewBusy = true;
    reviewNote = null;
    try {
      reviewNote = { ok: true, text: await pullsApi.review(accountId, detail.repo, detail.number, event, reviewText.trim()) };
      reviewText = "";
      reviewing = false;
      pullRequests.markStale();
      await load();
      pullRequests.refresh(true);
    } catch (e) {
      reviewNote = { ok: false, text: String(e) };
    } finally {
      reviewBusy = false;
    }
  }

  const confirmMessage = $derived(
    detail
      ? tr("{branch} mergen — {method}. Dit is lastig ongedaan te maken.", "Merge {branch} — {method}. This is hard to undo.", { branch: detail.headBranch, method: methodNames[method] }) +
          (detail.checkSummary !== "passing" && detail.checks.length ? "\n" + tr("Niet alle checks zijn geslaagd.", "Not all checks passed.") : "")
      : "",
  );

  const glyphs = { open: "open", draft: "draft", merged: "merged", closed: "closed" } as const;

  function activityTone(event: string): string {
    if (event === "merged") return "merged";
    if (event === "closed") return "bad";
    if (event === "reopened") return "good";
    if (event === "head_ref_force_pushed") return "wait";
    return "";
  }

  const fileLetter = (f: PullRequestFile) =>
    f.status === "added" ? ["A", "good"] : f.status === "removed" ? ["D", "bad"] : f.status === "renamed" || f.status === "copied" ? ["R", "merged"] : ["M", "wait"];
</script>

<div class="detail">
  <div class="head">
    <button class="ghost icon" title={tr("Terug", "Back")} aria-label={tr("Terug", "Back")} onclick={onback}>‹</button>
    <span class="id muted">{itemId(item)}</span>
    <span class="spacer"></span>
    {#if loading}<span class="faint small">{tr("Bezig…", "Loading…")}</span>{/if}
    <button class="ghost" title={tr("Vernieuwen", "Refresh")} disabled={loading} onclick={load}>{tr("Vernieuwen", "Refresh")}</button>
    {#if detail?.url ?? item.url}<button class="ghost" title={tr("Open op GitHub", "Open on GitHub")} onclick={() => open(detail?.url ?? item.url)}>{tr("Open op GitHub", "Open on GitHub")} ↗</button>{/if}
  </div>

  {#if detail}
    <div class="summary">
      <strong class="title">{detail.title}</strong>
      <div class="meta faint">
        <span class="state {detail.state}"><PullGlyph glyph={glyphs[detail.state]} size={12} /> {detailStateNames[detail.state]}</span>
        <span>@{detail.author}</span>·
        <span class="mono branch" title="{detail.headBranch} → {detail.baseBranch}">{detail.headBranch} → {detail.baseBranch}</span>·
        <span class="good">+{detail.additions}</span><span class="bad">−{detail.deletions}</span>
      </div>
    </div>

    <div class="tabs" role="tablist">
      <button role="tab" aria-selected={tab === "conversation"} class:on={tab === "conversation"} onclick={() => ((tab = "conversation"), (openFile = null), (openCheck = null))}>{tr("Gesprek", "Conversation")}</button>
      <button role="tab" aria-selected={tab === "commits"} class:on={tab === "commits"} onclick={() => ((tab = "commits"), (openFile = null), (openCheck = null))}>{tr("Commits ({n})", "Commits ({n})", { n: detail.commits.length })}</button>
      <button role="tab" aria-selected={tab === "files"} class:on={tab === "files"} onclick={() => ((tab = "files"), (openCheck = null))}>{tr("Bestanden ({n})", "Files ({n})", { n: Math.max(detail.changedFiles, detail.files.length) })}</button>
    </div>

    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
    <div class="content" onclick={linkClick}>
      {#if tab === "conversation" && shownCheck}
        <CheckLog accountId={accountId} repo={detail.repo} check={shownCheck} onback={() => (openCheck = null)} />
      {:else if tab === "conversation"}
        <div class="card markdown">
          {#if detail.body}{@html renderMarkdown(detail.body)}{:else}<span class="faint">{tr("Geen beschrijving.", "No description.")}</span>{/if}
        </div>
        <div class="section">
          <div class="label faint">{tr("Checks", "Checks")}</div>
          {#each detail.checks as check, i (i)}
            <!-- A GitHub Actions job opens its steps and log here; a check from another app only has its own page. -->
            <button class="line" disabled={!check.url} onclick={() => (jobId(check.url) !== null ? (openCheck = check) : open(check.url))}>
              <span class="mark">
                {#if check.outcome === "passing"}<span class="good">✓</span>{:else if check.outcome === "failing"}<span class="bad">✕</span>{:else if check.outcome === "pending"}<span class="dot" class:working={check.running} class:waiting={!check.running}></span>{:else}<span class="faint">–</span>{/if}
              </span>
              <span class="name">{check.name}</span>
              <span class="small ellipsis" class:faint={check.outcome !== "failing"} class:bad={check.outcome === "failing"}>{ciStatusLine(check, now)}</span>
              <span class="spacer"></span>
              {#if check.url}<span class="faint small">{jobId(check.url) !== null ? "›" : "↗"}</span>{/if}
            </button>
          {:else}
            <span class="faint small">{tr("Geen checks op de laatste commit.", "No checks on the latest commit.")}</span>
          {/each}
        </div>
        <div class="section">
          <div class="label faint">{tr("Tijdlijn", "Timeline")}</div>
          {#if detail.created}
            {@render activity("good", "open", detail.author, tr("opende deze pull request", "opened this pull request"), detail.created)}
          {/if}
          {#each detail.events as event (event.id)}
            {@render timelineRow(event)}
          {:else}
            <span class="faint small">{tr("Nog geen reviews of reacties.", "No reviews or comments yet.")}</span>
          {/each}
        </div>
      {:else if tab === "commits"}
        {#each detail.commits as commit (commit.sha)}
          <button class="row" onclick={() => open(commitUrl(commit.sha))}>
            <span class="mono muted">{commit.sha.slice(0, 7)}</span>
            <span class="stack">
              <span class="name">{commit.message.split("\n")[0]}</span>
              <span class="faint small">@{commit.author}{#if commit.date} · {ago(commit.date, now)}{/if}</span>
            </span>
          </button>
        {:else}
          <span class="faint small">{tr("Geen commits.", "No commits.")}</span>
        {/each}
      {:else if file}
        <div class="filehead">
          <button class="ghost icon" title={tr("Terug", "Back")} aria-label={tr("Terug", "Back")} onclick={() => (openFile = null)}>‹</button>
          {@render letter(file)}
          <span class="stack">
            <span class="mono path" title={file.path}>{file.path}</span>
            {#if file.previousPath}<span class="mono faint small path">{file.previousPath} →</span>{/if}
          </span>
          <span class="good small">+{file.additions}</span><span class="bad small">−{file.deletions}</span>
          <button class="ghost icon" title={tr("Vorig bestand", "Previous file")} aria-label={tr("Vorig bestand", "Previous file")} disabled={fileIndex <= 0} onclick={() => (openFile = detail!.files[fileIndex - 1].path)}>↑</button>
          <button class="ghost icon" title={tr("Volgend bestand", "Next file")} aria-label={tr("Volgend bestand", "Next file")} disabled={fileIndex + 1 >= detail.files.length} onclick={() => (openFile = detail!.files[fileIndex + 1].path)}>↓</button>
        </div>
        {#if file.patch}
          <pre class="diff">{#each diffLines(file.patch) as line, i (i)}<span class={line.kind}>{line.text}</span>
{/each}</pre>
        {:else}
          <div class="empty">
            <strong>{tr("Geen diff om te tonen", "No diff to show")}</strong>
            <span class="muted small">{tr("GitHub laat de diff van binaire en heel grote bestanden weg. Open de pull request op GitHub om hem te zien.", "GitHub leaves out the diff of binary and very large files. Open the pull request on GitHub to see it.")}</span>
          </div>
        {/if}
      {:else}
        {#each detail.files as f (f.path)}
          <button class="row" onclick={() => (openFile = f.path)}>
            {@render letter(f)}
            <span class="mono path" title={f.path}>{f.path}</span>
            <span class="spacer"></span>
            <span class="good small">+{f.additions}</span><span class="bad small">−{f.deletions}</span>
          </button>
        {:else}
          <span class="faint small">{tr("Geen gewijzigde bestanden.", "No changed files.")}</span>
        {/each}
      {/if}
    </div>

    <div class="bar">
      {#if detail.isOpen}
        {#if reviewing}
          <textarea rows="3" placeholder={tr("Opmerking bij je review (verplicht voor wijzigingen en reacties)", "Comment on your review (required for changes and comments)")} bind:value={reviewText}></textarea>
          <div class="barline">
            <button class="ghost" disabled={reviewBusy} onclick={() => ((reviewing = false), (reviewNote = null))}>{tr("Annuleren", "Cancel")}</button>
            <span class="spacer"></span>
            <button disabled={reviewBusy} onclick={() => sendReview("COMMENT")}>{tr("Reageren", "Comment")}</button>
            <button disabled={reviewBusy} onclick={() => sendReview("REQUEST_CHANGES")}>{tr("Wijzigingen vragen", "Request changes")}</button>
            <button class="primary" disabled={reviewBusy} onclick={() => sendReview("APPROVE")}>{tr("Goedkeuren", "Approve")}</button>
          </div>
        {:else}
          <div class="barline">
            <span class="muted small grow">{tr("Review", "Review")}</span>
            <button onclick={() => ((reviewing = true), (reviewNote = null))}>{tr("Review schrijven…", "Write review…")}</button>
            <button class="primary" disabled={reviewBusy} onclick={() => sendReview("APPROVE")}>{reviewBusy ? tr("Bezig…", "Sending…") : tr("Goedkeuren", "Approve")}</button>
          </div>
        {/if}
        {#if reviewNote}<span class={reviewNote.ok ? "good small" : "err"}>{reviewNote.text}</span>{/if}
      {/if}
      {#if confirming}
        <!-- The confirmation stays inside the bar, so no separate window is involved. -->
        <div class="barline">
          <span class="wait"><PullGlyph glyph="merged" size={14} /></span>
          <span class="stack grow">
            <strong>{tr("#{number} mergen in {branch}?", "Merge #{number} into {branch}?", { number: detail.number, branch: detail.baseBranch })}</strong>
            <span class="muted small pre">{confirmMessage}</span>
          </span>
          <button class="ghost" onclick={() => (confirming = false)}>{tr("Annuleren", "Cancel")}</button>
          <button class="primary" onclick={merge}>{tr("Pull request mergen", "Merge pull request")}</button>
        </div>
      {:else}
        <div class="barline">
          <span class={ready ? "good" : detail.canMerge ? "wait" : "faint"}>{ready ? "✓" : detail.canMerge ? "⚠" : "ⓘ"}</span>
          <span class="muted small grow">{noteText(detail.mergeNote)}</span>
          {#if detail.isOpen && !detail.canMerge && detail.state !== "draft" && detail.mergeNote !== "conflict"}<span class="faint small">{tr("Wacht op merge…", "Waiting to merge…")}</span>{/if}
          {#if detail.isOpen && detail.canMerge && detail.methods.length}
            <select aria-label={tr("Merge-methode", "Merge method")} value={method} disabled={merging} onchange={(e) => pick(e.currentTarget.value as MergeMethod)}>
              {#each detail.methods as m (m)}<option value={m}>{methodNames[m]}</option>{/each}
            </select>
            <button class="primary" disabled={!detail.canMerge || merging} onclick={() => ((mergeError = null), (confirming = true))}>{merging ? tr("Bezig met mergen…", "Merging…") : tr("Mergen", "Merge")}</button>
          {/if}
        </div>
      {/if}
      {#if mergeError}<span class="err">{mergeError}</span>{/if}
    </div>
  {:else if error}
    <div class="empty">
      <strong>{tr("Kon de pull request niet laden", "Couldn't load the pull request")}</strong>
      <span class="err">{error}</span>
      <button class="primary" onclick={load}>{tr("Opnieuw proberen", "Try again")}</button>
    </div>
  {:else}
    <p class="faint small">{tr("Pull request laden…", "Loading pull request…")}</p>
  {/if}
</div>

{#snippet activity(tone: string, glyph: "open" | "merged" | "closed" | "", author: string, sentence: string, date: string | null)}
  <div class="activity">
    <span class="mark {tone}">{#if glyph}<PullGlyph {glyph} size={12} />{:else}•{/if}</span>
    <span class="grow"><strong>@{author}</strong> <span class="muted">{sentence}</span></span>
    {#if date}<span class="faint small">{ago(date, now)}</span>{/if}
  </div>
{/snippet}

{#snippet timelineRow(event: PullRequestEvent)}
  {#if event.kind === "commit"}
    {@const sha = event.sha}
    <button class="activity line" onclick={() => open(commitUrl(sha))}>
      <span class="mark faint">◦</span>
      <span class="mono muted">{sha.slice(0, 7)}</span>
      <span class="name grow">{event.body}</span>
      <span class="faint small">@{event.author}</span>
      {#if event.date}<span class="faint small">{ago(event.date, now)}</span>{/if}
    </button>
  {:else if event.kind === "activity"}
    {@render activity(activityTone(event.event), event.event === "merged" ? "merged" : event.event === "closed" ? "closed" : "", event.author, activitySentence(event.event, event.detail), event.date)}
  {:else}
    {@const label = eventLabel(event)}
    <div class="card">
      <div class="cardhead">
        <strong>@{event.author}</strong>
        <span class="small ellipsis {label.tone}">{label.text}</span>
        <span class="spacer"></span>
        {#if event.date}<span class="faint small">{ago(event.date, now)}</span>{/if}
        {#if event.url}<button class="ghost tiny" title={tr("Open op GitHub", "Open on GitHub")} onclick={() => open(event.url)}>↗</button>{/if}
      </div>
      {#if event.body}<div class="markdown body">{@html renderMarkdown(event.body)}</div>{/if}
    </div>
  {/if}
{/snippet}

{#snippet letter(f: PullRequestFile)}
  {@const [l, tone] = fileLetter(f)}
  <span class="mono letter {tone}">{l}</span>
{/snippet}

<style>
  .detail { display: flex; flex-direction: column; gap: 12px; height: 100%; min-height: 0; }
  .head, .filehead { display: flex; align-items: center; gap: 6px; min-height: 30px; }
  .icon { width: 28px; height: 28px; padding: 0; font-size: 16px; }
  .tiny { padding: 0 4px; font-size: 11px; }
  .id { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .spacer, .grow { flex: 1; min-width: 0; }
  .small { font-size: 11.5px; }
  .mono { font-family: var(--mono); font-size: 11.5px; }
  .ellipsis, .name, .path, .branch { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .path { direction: rtl; text-align: left; }
  .summary { display: flex; flex-direction: column; gap: 6px; }
  .title { font-size: 15px; user-select: text; }
  .meta { display: flex; align-items: center; gap: 6px; font-size: 11.5px; min-width: 0; }
  .state { display: inline-flex; align-items: center; gap: 3px; font-weight: 600; font-size: 11px; padding: 2px 7px 2px 5px; border-radius: 10px; flex: none; }
  .state.open { color: var(--mint); background: rgba(70, 224, 166, 0.14); }
  .state.draft { color: var(--text2); background: rgba(156, 154, 168, 0.14); }
  .state.merged { color: var(--violet); background: rgba(180, 140, 255, 0.14); }
  .state.closed { color: var(--coral); background: rgba(255, 107, 107, 0.14); }
  .tabs { display: flex; gap: 4px; }
  .tabs button { background: none; border: none; color: var(--text3); padding: 5px 10px; border-radius: 8px; }
  .tabs button.on, .tabs button:hover { color: var(--paper); background: var(--smoke); }
  .content { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 16px; }
  .card { padding: 12px; border-radius: 12px; background: var(--field); display: flex; flex-direction: column; gap: 6px; }
  .cardhead { display: flex; align-items: center; gap: 6px; min-width: 0; }
  .body { font-size: 12.5px; }
  .section { display: flex; flex-direction: column; gap: 6px; }
  .label { font-size: 11.5px; font-weight: 600; }
  .line, .activity { display: flex; align-items: center; gap: 8px; padding: 3px 4px; background: none; border: none; text-align: left; border-radius: 7px; min-width: 0; font-size: 12.5px; }
  button.line:hover:not(:disabled), button.activity:hover { background: var(--smoke); }
  .line:disabled { opacity: 1; cursor: default; }
  .mark { width: 16px; display: grid; place-items: center; flex: none; }
  .row { display: flex; align-items: center; gap: 10px; padding: 7px 10px; background: none; border: none; border-radius: 10px; text-align: left; min-width: 0; }
  .row:hover { background: var(--smoke); }
  .stack { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .letter { width: 14px; font-weight: 600; flex: none; }
  .good { color: var(--mint); }
  .bad { color: var(--coral); }
  .wait { color: var(--amber); }
  .merged { color: var(--violet); }
  .diff { margin: 0; font-family: var(--mono); font-size: 11.5px; line-height: 1.45; background: var(--field); border: 1px solid var(--line2); border-radius: 10px; padding: 8px 10px; overflow: auto; white-space: pre; user-select: text; }
  .diff .add { color: var(--mint); }
  .diff .remove { color: var(--coral); }
  .diff .hunk { color: var(--violet); }
  .diff .context { color: var(--text2); }
  .empty { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; padding-top: 8px; }
  .bar { display: flex; flex-direction: column; gap: 6px; padding: 12px; border-radius: var(--radius); background: var(--field); flex: none; }
  .barline { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .pre { white-space: pre-line; }
  .err { color: var(--coral); font-size: 12px; user-select: text; }
  select { font-size: 12px; padding: 5px 8px; }
  textarea { width: 100%; box-sizing: border-box; resize: vertical; font-size: 12.5px; }
</style>
