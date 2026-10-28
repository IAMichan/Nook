<script lang="ts">
  // GitHub in Chats as a dashboard instead of a list: your pull requests and reviews sorted by what you have to do
  // about each (review, fix, merge, wait), the issues assigned to you, a search, and a click that opens the pull
  // request beside the list. The data is the pull request store of Agents › Pull requests.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import type { IssueItem, PullRequestItem } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import { itemId, LANES, pullsApi, laneCounts, matchesQuery, sizeLabel, triage, type Lane, type Reason, type Triaged } from "../../lib/pulls";
  import { pullRequests } from "../../lib/pulls.svelte";
  import { ago } from "../agents/time";
  import PullGlyph from "../agents/pulls/PullGlyph.svelte";

  let { active, onopen }: { active: string | null; onopen: (account: string, item: PullRequestItem) => void } = $props();

  type Pick = Lane | "issues" | "all";

  let pick = $state<Pick>("all");
  let query = $state("");
  let now = $state(Date.now());

  $effect(() => {
    pullRequests.refresh();
    const timer = setInterval(() => {
      now = Date.now();
      pullRequests.refresh();
    }, 60_000);
    return () => clearInterval(timer);
  });

  const accounts = $derived(pullRequests.accounts);
  const all = $derived(triage(accounts));
  const counts = $derived(laneCounts(all));
  const issues = $derived(
    accounts
      .flatMap((a) => a.issues)
      .filter((i, n, list) => list.findIndex((o) => o.repo === i.repo && o.number === i.number) === n)
      .sort((x, y) => (y.updated ?? "").localeCompare(x.updated ?? "")),
  );
  const shown = $derived(all.filter((t) => (pick === "all" || pick === t.lane) && matchesQuery(query, t.item)));
  const shownIssues = $derived(pick === "all" || pick === "issues" ? issues.filter((i) => matchesQuery(query, i)) : []);
  const failed = $derived(accounts.filter((a) => a.error));
  const expired = $derived(failed.some((a) => a.errorKind === "auth"));
  const urgent = $derived(counts.review + counts.fix);
  const groups = $derived(LANES.map((l) => ({ lane: l, items: shown.filter((t) => t.lane === l) })).filter((g) => g.items.length));
  const nothing = $derived(pullRequests.loaded && !shown.length && !shownIssues.length);
  const filtered = $derived(query !== "" || pick !== "all");

  const titles: Record<Lane, [string, string]> = {
    review: ["Wacht op jouw review", "Waiting for your review"],
    fix: ["Moet je fixen", "Needs your fix"],
    ready: ["Klaar om te mergen", "Ready to merge"],
    waiting: ["Wachten op anderen", "Waiting on others"],
    draft: ["Concepten", "Drafts"],
    merged: ["Onlangs gemerged", "Recently merged"],
  };
  const hints: Record<Lane, [string, string]> = {
    review: ["Iemand vroeg jou om mee te kijken.", "Someone asked you to take a look."],
    fix: ["CI faalt, wijzigingen gevraagd of een conflict.", "CI is failing, changes were requested or there is a conflict."],
    ready: ["Goedgekeurd en groen: alleen mergen nog.", "Approved and green: only the merge is left."],
    waiting: ["CI loopt nog of er is nog geen review.", "CI is still running or no review yet."],
    draft: ["Nog niet klaar voor review.", "Not ready for review yet."],
    merged: ["Je laatste samengevoegde pull requests.", "Your latest merged pull requests."],
  };
  const reasonText: Record<Reason, [string, string]> = {
    reviewRequested: ["review gevraagd", "review requested"],
    failing: ["CI faalt", "CI failing"],
    changes: ["wijzigingen gevraagd", "changes requested"],
    conflict: ["conflict", "conflict"],
    approved: ["goedgekeurd", "approved"],
    passing: ["CI groen", "CI green"],
    pending: ["CI loopt", "CI running"],
    needsReview: ["wacht op review", "needs review"],
    draft: ["concept", "draft"],
    merged: ["gemerged", "merged"],
  };
  const tone = (r: Reason) =>
    r === "failing" || r === "changes" || r === "conflict" ? "bad" : r === "approved" || r === "passing" ? "good" : r === "merged" ? "merged" : r === "reviewRequested" ? "iris" : "";
  const word = (pair: [string, string]) => tr(pair[0], pair[1]);

  const tiles = $derived<{ id: Pick; label: string; count: number; tone: string }[]>([
    { id: "review", label: "Review", count: counts.review, tone: "iris" },
    { id: "fix", label: tr("Fixen", "Fix"), count: counts.fix, tone: "bad" },
    { id: "ready", label: tr("Mergen", "Merge"), count: counts.ready, tone: "good" },
    { id: "waiting", label: tr("Wachten", "Waiting"), count: counts.waiting, tone: "" },
    { id: "draft", label: tr("Concepten", "Drafts"), count: counts.draft, tone: "" },
    { id: "issues", label: "Issues", count: issues.length, tone: "wait" },
  ]);

  function settings() {
    try {
      localStorage.setItem("settings.section", "accounts");
    } catch {
      // The window opens on its last section instead.
    }
    api.showMain("settings");
  }

  /// Quick approval from the list: the first click asks, the second approves with the account the row is listed under.
  let confirm = $state<string | null>(null);
  let busy = $state<string | null>(null);
  let result = $state<{ id: string; ok: boolean; text: string } | null>(null);

  async function approve(t: Triaged) {
    const id = `${t.account} ${itemId(t.item)}`;
    if (confirm !== id) {
      confirm = id;
      result = null;
      return;
    }
    confirm = null;
    busy = id;
    try {
      const text = await pullsApi.review(t.account, t.item.repo, t.item.number, "APPROVE", "");
      result = { id, ok: true, text };
      pullRequests.markStale();
      pullRequests.refresh(true);
    } catch (e) {
      result = { id, ok: false, text: String(e) };
    } finally {
      busy = null;
    }
  }

  function web(url: string | null) {
    if (url && /^https:\/\//.test(url)) openUrl(url).catch(() => {});
  }
</script>

<div class="gh">
  <div class="top">
    <input class="find" placeholder={tr("Zoek op titel, repo, #nummer of @auteur", "Search title, repo, #number or @author")} bind:value={query} onkeydown={(e) => e.key === "Escape" && (query = "")} />
    <button class="small" title={tr("Vernieuwen", "Refresh")} disabled={pullRequests.loading} onclick={() => pullRequests.refresh(true)}>{pullRequests.loading ? "…" : "↻"}</button>
    <button class="small" title={tr("Open GitHub", "Open GitHub")} onclick={() => web("https://github.com/pulls")}>↗</button>
  </div>

  <div class="tiles" role="tablist">
    <button class="tile" class:on={pick === "all"} onclick={() => (pick = "all")}>
      <b>{urgent}</b><span>{urgent === 1 ? tr("wacht op jou", "needs you") : tr("wachten op jou", "need you")}</span>
    </button>
    {#each tiles as t (t.id)}
      <button class="tile {t.tone}" class:on={pick === t.id} class:zero={!t.count} onclick={() => (pick = pick === t.id ? "all" : t.id)}>
        <b>{t.count}</b><span>{t.label}</span>
      </button>
    {/each}
  </div>

  {#if expired}
    <div class="warn">
      <strong>{tr("GitHub-login verlopen", "GitHub sign-in expired")}</strong>
      <span class="faint">{tr("GitHub weigerde je token. Log opnieuw in via Instellingen.", "GitHub rejected your token. Sign in again in Settings.")}</span>
      <button class="small" onclick={settings}>{tr("Instellingen", "Settings")}</button>
    </div>
  {:else if failed.length}
    <p class="warn faint">{failed[0].error}</p>
  {/if}

  {#if !pullRequests.loaded}
    <p class="faint note">{tr("Laden…", "Loading…")}</p>
  {:else if nothing}
    <div class="clear">
      <strong>{filtered ? tr("Niets gevonden", "Nothing found") : tr("Alles afgehandeld", "All clear")}</strong>
      <span class="faint">
        {filtered ? tr("Niets past bij je zoekopdracht of filter.", "Nothing matches your search or filter.") : tr("Geen reviews, geen falende CI en geen open issues op jouw naam.", "No reviews, no failing CI and no open issues in your name.")}
      </span>
      {#if filtered}<button class="small" onclick={() => ((query = ""), (pick = "all"))}>{tr("Wis filter", "Clear filter")}</button>{/if}
    </div>
  {/if}

  <div class="scroll">
    {#each groups as g (g.lane)}
      <section>
        <h5 class={g.lane}>{word(titles[g.lane])}<span class="n">{g.items.length}</span></h5>
        {#if pick === g.lane}<p class="hint faint">{word(hints[g.lane])}</p>{/if}
        {#each g.items as t (itemId(t.item))}
          {@render pr(t)}
        {/each}
      </section>
    {/each}

    {#if shownIssues.length}
      <section>
        <h5 class="wait">{tr("Issues op jouw naam", "Issues assigned to you")}<span class="n">{shownIssues.length}</span></h5>
        {#each shownIssues as i (`${i.repo}#${i.number}`)}
          {@render issue(i)}
        {/each}
      </section>
    {/if}
  </div>
</div>

{#snippet pr(t: Triaged)}
  {@const i = t.item}
  <div class="row" class:active={active === `${t.account} ${itemId(i)}`}>
    <button class="open" onclick={() => onopen(t.account, i)} title={tr("Open in Nook", "Open in Nook")}>
      <span class="mark">
        {#if i.state === "merged"}<span class="merged"><PullGlyph glyph="merged" size={13} /></span>
        {:else if i.draft}<span class="faint"><PullGlyph glyph="draft" size={13} /></span>
        {:else if i.ci === "passing"}<span class="good">✓</span>
        {:else if i.ci === "failing"}<span class="bad">✕</span>
        {:else if i.ci === "pending"}<span class="dot waiting"></span>
        {:else}<span class="dot hollow"></span>{/if}
      </span>
      <span class="what">
        <span class="line"><span class="title">{i.title}</span><span class="when faint">{ago(i.updated, now)}</span></span>
        <span class="sub faint">
          {itemId(i)}{#if t.lane === "review" && i.author} · @{i.author}{/if}{#if i.comments} · {i.comments} {tr("reacties", "comments")}{/if}{#if sizeLabel(i)} · {sizeLabel(i)}{/if}
        </span>
        <span class="pills">
          {#each t.reasons as r (r)}<span class="pill {tone(r)}">{word(reasonText[r])}</span>{/each}
        </span>
      </span>
    </button>
    {#if t.lane === "review"}
      {@const id = `${t.account} ${itemId(i)}`}
      <button class="approve" class:ask={confirm === id} disabled={busy === id} onclick={() => approve(t)} onblur={() => confirm === id && (confirm = null)}>
        {busy === id ? "…" : confirm === id ? tr("Zeker?", "Sure?") : tr("Keur goed", "Approve")}
      </button>
    {/if}
    <button class="ext" title={tr("Open op GitHub", "Open on GitHub")} aria-label={tr("Open op GitHub", "Open on GitHub")} onclick={() => web(i.url)}>↗</button>
  </div>
  {#if result && result.id === `${t.account} ${itemId(i)}`}
    <p class="result {result.ok ? 'good' : 'bad'}">{result.text}</p>
  {/if}
{/snippet}

{#snippet issue(i: IssueItem)}
  <div class="row">
    <button class="open" onclick={() => web(i.url)} title={tr("Open op GitHub", "Open on GitHub")}>
      <span class="mark"><span class="wait">●</span></span>
      <span class="what">
        <span class="line"><span class="title">{i.title}</span><span class="when faint">{ago(i.updated, now)}</span></span>
        <span class="sub faint">{i.repo}#{i.number} · @{i.author}{#if i.comments} · {i.comments} {tr("reacties", "comments")}{/if}</span>
        {#if i.labels.length}<span class="pills">{#each i.labels as l (l)}<span class="pill">{l}</span>{/each}</span>{/if}
      </span>
    </button>
    <button class="ext" aria-label={tr("Open op GitHub", "Open on GitHub")} onclick={() => web(i.url)}>↗</button>
  </div>
{/snippet}

<style>
  .gh { display: flex; flex-direction: column; min-height: 0; flex: 1; }
  .top { display: flex; gap: 6px; padding: 4px 12px 8px; }
  .find { flex: 1; min-width: 0; font-size: 12px; padding: 5px 10px; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(70px, 1fr)); gap: 6px; padding: 0 12px 8px; }
  .tile { display: grid; gap: 1px; text-align: left; padding: 6px 8px; border-radius: var(--radius-control); background: var(--smoke); border: 1px solid var(--line); color: var(--text2); }
  .tile b { font-size: 16px; line-height: 1.1; color: var(--paper); }
  .tile span { font-size: 10px; letter-spacing: 0.04em; text-transform: uppercase; }
  .tile.on { border-color: color-mix(in srgb, var(--iris) 55%, var(--line)); }
  .tile.zero b { color: var(--text3); }
  .tile.iris:not(.zero) b { color: var(--iris); }
  .tile.bad:not(.zero) b { color: var(--coral); }
  .tile.good:not(.zero) b { color: var(--mint); }
  .tile.wait:not(.zero) b { color: var(--amber); }
  .warn { display: grid; gap: 4px; margin: 0 12px 8px; padding: 8px 10px; font-size: 11px; border-radius: var(--radius-control); background: rgba(255, 107, 107, 0.1); }
  .warn button { justify-self: start; }
  .clear { display: grid; gap: 6px; justify-items: start; margin: 8px 16px; font-size: 12px; }
  .clear strong { font-size: 13px; }
  .note { margin: 4px 16px; font-size: 11px; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; padding: 0 8px 12px; }
  h5 { display: flex; align-items: center; gap: 6px; margin: 12px 4px 4px; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text3); }
  h5.review { color: var(--iris); }
  h5.fix { color: var(--coral); }
  h5.ready { color: var(--mint); }
  h5.wait { color: var(--amber); }
  .n { font-size: 10px; padding: 0 6px; border-radius: 999px; background: var(--smoke); color: var(--text2); }
  .hint { margin: 0 4px 4px; font-size: 11px; }
  .row { display: flex; align-items: stretch; border: 1px solid transparent; border-radius: var(--radius-control); margin-bottom: 2px; }
  .row:hover { background: var(--row-hover); }
  .row.active { background: var(--smoke); border-color: var(--line2); }
  .open { flex: 1; min-width: 0; display: flex; gap: 10px; align-items: flex-start; text-align: left; padding: 8px; border: 0; background: transparent; }
  .approve { flex: none; align-self: center; margin-right: 4px; font-size: 10px; padding: 3px 8px; opacity: 0; }
  .row:hover .approve, .approve.ask { opacity: 1; }
  .approve.ask { border-color: var(--mint); color: var(--mint); }
  .result { margin: 0 8px 6px 34px; font-size: 11px; }
  .ext { flex: none; width: 26px; border: 0; background: transparent; color: var(--text3); opacity: 0; }
  .row:hover .ext { opacity: 1; }
  .ext:hover { color: var(--paper); }
  .mark { width: 16px; flex: none; display: grid; place-items: center; padding-top: 1px; }
  .what { min-width: 0; flex: 1; display: grid; gap: 2px; }
  .line { display: flex; align-items: baseline; gap: 8px; }
  .title { min-width: 0; flex: 1; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { flex: none; font-size: 10px; }
  .sub { font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pills { display: flex; flex-wrap: wrap; gap: 4px; }
  .pills:empty { display: none; }
  .pill { font-size: 10px; padding: 1px 7px; border-radius: 999px; background: var(--smoke); color: var(--text2); }
  .pill.bad { color: var(--coral); background: rgba(255, 107, 107, 0.12); }
  .pill.good { color: var(--mint); background: rgba(70, 224, 166, 0.12); }
  .pill.iris { color: var(--iris); background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .pill.merged { color: var(--violet); background: rgba(180, 140, 255, 0.14); }
  .good { color: var(--mint); }
  .bad { color: var(--coral); }
  .wait { color: var(--amber); }
  .merged { color: var(--violet); display: grid; }
  .dot.hollow { border: 1.2px solid var(--text3); }
  .small { font-size: 11px; padding: 4px 10px; }
</style>
