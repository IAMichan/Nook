<script lang="ts">
  // Pull requests, as the iPhone's sheet (`PullRequestListView`, `PullRequestDetailView`): the Mac's list (yours, for
  // your review, watched) or a session's linked ones, and one in full with its summary, checks and files. Pick lines in
  // a file to comment, mark files viewed, then send one review; Merge as the forge allows; Work on this starts a session
  // on its branch. The Mac acts with its own accounts, only at the head you saw, and refuses what its page would.
  import { onMount } from "svelte";
  import { companion, has, may, relative, Feature, type ClientView, type LineComment, type PullAction, type PullDetail, type PullDigest, type PullThread, type LaunchOptions } from "../../lib/companion";
  import { ATTENTIONS, SORTS, STATES, counted, sections, type Attention, type PullGrouping, type PullSort, type PullState } from "../../lib/companion-pulls";
  import SearchField from "../../components/ui/SearchField.svelte";
  import { lineComment, positions } from "../../lib/patch";
  import { renderMarkdown } from "../../lib/markdown";
  import { richContent } from "../../lib/rich";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import Ico from "../../components/ui/Ico.svelte";
  import FileCard from "./ui/FileCard.svelte";
  import EmptyState from "../../components/ui/EmptyState.svelte";
  import Dialog from "../../components/ui/Dialog.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ComposerPill from "./ui/ComposerPill.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import Banner from "../../components/ui/Banner.svelte";

  let { view, session, onclose, took, onstarted }: { view: ClientView; session?: string; onclose: () => void; took: (v: ClientView) => void; onstarted: (id: string) => void } = $props();

  let list = $state<PullDigest[] | null>(null);
  let open = $state<string | null>(null);
  let detail = $state<PullDetail | null>(null);
  let segment = $state<"summary" | "conversation" | "checks" | "files">("summary");
  // The list as the Mac's (`pullActions`): the chips, the search, and state, order and grouping kept across launches.
  let query = $state("");
  let attention = $state<Attention | null>(null);
  let pstate = $state<PullState>((localStorage.getItem("pulls.state") as PullState) || "open");
  let sort = $state<PullSort>((localStorage.getItem("pulls.sort") as PullSort) || "attention");
  let grouping = $state<PullGrouping>((localStorage.getItem("pulls.grouping") as PullGrouping) || "involvement");
  $effect(() => { localStorage.setItem("pulls.state", pstate); localStorage.setItem("pulls.sort", sort); localStorage.setItem("pulls.grouping", grouping); });
  const full = $derived(!session && has(view, Feature.pullActions));
  const rich = $derived(has(view, Feature.pullActions) && !!detail?.actions);
  const allows = (kind: string) => rich && !!detail?.actions?.includes(kind) && canAct;
  let confirming = $state<null | { kind: PullAction["kind"]; pull?: PullDigest }>(null);
  let replying = $state<null | { thread: PullThread; text: string }>(null);
  let comment = $state("");
  let showResolved = $state(false);
  let held = false;
  let press: ReturnType<typeof setTimeout> | undefined;
  let notes = $state<LineComment[]>([]);
  let asking = $state<{ path: string; lines: string[]; from: number; to: number; note: string } | null>(null);
  let sheet = $state<null | "review" | "work">(null);
  let verdict = $state<"comment" | "approve" | "requestChanges">("comment");
  let words = $state("");
  let task = $state("");
  let options = $state<LaunchOptions | null>(null);
  let agent = $state("");
  let model = $state("");
  let menu = $state<{ anchor: DOMRect; sections: MenuItem[][] } | null>(null);
  let confirmMerge = $state(false);
  let failed = $state<string | null>(null);
  let mergeMethod = $state("merge");
  const canAct = $derived(may(view, "operate") && view.phase === "connected");

  async function loadList() {
    const r = await companion.call(session ? { op: "pulls", session } : { op: "pulls" });
    took(r.view);
    list = r.response?.pulls ?? list ?? [];
  }
  async function loadDetail(url: string) {
    const r = await companion.call({ op: "pull", item: url });
    took(r.view);
    if (r.response?.pull) detail = r.response.pull;
  }
  onMount(loadList);

  function openPull(url: string) {
    open = url;
    detail = null;
    notes = [];
    segment = "summary";
    loadDetail(url);
  }

  async function act(action: PullAction | undefined) {
    if (!detail || !action) return null;
    failed = null;
    const r = await companion.call({ op: "pullAct", item: detail.url, pullAction: { ...action, head: detail.headSHA } });
    if (!r.response) {
      haptic("warning");
      failed = r.view.notice;
      companion.clearNotice();
      took({ ...r.view, notice: null });
      return null;
    }
    took(r.view);
    if (r.response.pull) detail = r.response.pull;
    else loadDetail(detail.url);
    return r.response;
  }

  async function sendReview() {
    const r = await act({ kind: verdict, body: words.trim() || undefined, comments: notes.length ? notes : undefined });
    if (r) { haptic("success"); notes = []; words = ""; sheet = null; }
  }

  async function merge(method: string) {
    const r = await act({ kind: "merge", method });
    if (r) { haptic("success"); loadList(); }
  }

  async function openWork() {
    sheet = "work";
    if (!options) {
      const r = await companion.call({ op: "options" });
      options = r.response?.launch ?? null;
      agent = options?.defaultAgent ?? options?.agents[0]?.id ?? "";
      model = options?.agents.find((a) => a.id === agent)?.defaultModel ?? "";
    }
  }
  async function startWork(text: string) {
    if (!detail || !agent) return;
    const r = await companion.call({ op: "pullWork", pullWork: { url: detail.url, agent, task: text, model: model || undefined } });
    took(r.view);
    if (r.response?.created) { haptic("success"); onstarted(r.response.created); }
  }

  const counts = $derived(counted(list ?? [], query, pstate));
  const groups = $derived.by(() => {
    const all = list ?? [];
    if (session) return [{ title: "", rows: all }];
    if (full) {
      const title = (key: string) => grouping === "repository" ? key
        : ({ review: tr("Ter review voor jou", "For your review"), mine: tr("Van jou", "Yours"), watched: tr("Gevolgd", "Watched") } as Record<string, string>)[key] ?? tr("Gekoppeld aan sessies", "Linked to sessions");
      return sections(all, { query, state: pstate, attention, sort, grouping }).map((s) => ({ title: title(s.key), rows: s.pulls }));
    }
    return [
      { title: tr("Van jou", "Yours"), rows: all.filter((p) => p.group === "mine") },
      { title: tr("Ter review voor jou", "For your review"), rows: all.filter((p) => p.group === "review") },
      { title: tr("Gevolgd", "Watched"), rows: all.filter((p) => p.group === "watched" || p.group === "linked") },
    ].filter((g) => g.rows.length);
  });

  function mark(p: { state: string; conflict?: boolean }): { icon: string; tint: string } {
    if (p.conflict && (p.state === "open" || p.state === "draft")) return { icon: "triangle-alert", tint: "var(--coral)" };
    switch (p.state) {
      case "draft": return { icon: "circle-dashed", tint: "var(--text3)" };
      case "merged": return { icon: "git-merge", tint: "var(--violet)" };
      case "closed": return { icon: "circle-x", tint: "var(--coral)" };
      default: return { icon: "git-pull-request", tint: "var(--mint)" };
    }
  }
  const stateWord = (s: string) => ({ open: tr("Open", "Open"), draft: tr("Concept", "Draft"), merged: tr("Samengevoegd", "Merged"), closed: tr("Gesloten", "Closed") } as Record<string, string>)[s] ?? s;
  const blockerText = (b: string) => ({
    merged: tr("Al samengevoegd.", "Already merged."), closed: tr("Gesloten zonder samenvoegen.", "Closed without merging."),
    draft: tr("Een concept: markeer het eerst als klaar op je Mac of de forge.", "A draft: mark it ready on your Mac or the forge first."),
    access: tr("Je account kan niet samenvoegen in deze repository.", "Your account cannot merge into this repository."),
    conflict: tr("Conflicteert met de basisbranch.", "Conflicts with its base branch."),
    checks: tr("Checks mislukken: voeg het samen op je Mac als je het zeker weet.", "Checks fail: merge it on your Mac if you are sure."),
  } as Record<string, string>)[b] ?? tr("Kan nu niet vanaf je iPhone worden samengevoegd.", "Cannot be merged from your iPhone now.");
  const methodWord = (m: string) => (m === "squash" ? tr("Squash en samenvoegen", "Squash and merge") : m === "rebase" ? tr("Rebase en samenvoegen", "Rebase and merge") : tr("Merge-commit", "Merge commit"));
  const viewedCount = $derived(detail?.files.filter((f) => f.viewed === "viewed").length ?? 0);

  const chipWord = (a: Attention) => ({ review: tr("Review", "Review"), failing: tr("Mislukt", "Failing"), ready: tr("Klaar om samen te voegen", "Ready to merge") })[a];
  const stateTitle = (s: PullState) => ({ open: tr("Open", "Open"), closed: tr("Gesloten", "Closed"), merged: tr("Samengevoegd", "Merged"), all: tr("Alle statussen", "All states") })[s];
  const sortTitle = (s: PullSort) => ({
    attention: tr("Wat jou nodig heeft eerst", "Needs you first"), readiness: tr("Dichtst bij samenvoegen", "Closest to merging"),
    blockedOnMe: tr("Wacht op mij", "Blocked on me"), recent: tr("Recent bijgewerkt", "Recently updated"),
    oldest: tr("Langst niet bijgewerkt", "Least recently updated"), largest: tr("Grootste wijziging", "Largest change"), smallest: tr("Kleinste wijziging", "Smallest change"),
  })[s];
  const reviewWord = (r: string) => ({ approved: tr("Goedgekeurd", "Approved"), changesRequested: tr("Wijzigingen gevraagd", "Changes requested"), required: tr("Review nodig", "Review required") } as Record<string, string>)[r];
  const age = (t: number) => relative(t);

  function openFilters(e: MouseEvent) {
    const anchor = (e.currentTarget as HTMLElement).getBoundingClientRect();
    menu = { anchor, sections: [
      STATES.map((s) => ({ label: stateTitle(s), checked: pstate === s, onselect: () => (pstate = s) })),
      SORTS.map((s) => ({ label: sortTitle(s), checked: sort === s, onselect: () => (sort = s) })),
      [{ label: tr("Op betrokkenheid", "By involvement"), checked: grouping === "involvement", onselect: () => (grouping = "involvement") },
       { label: tr("Op repository", "By repository"), checked: grouping === "repository", onselect: () => (grouping = "repository") }],
      ...(query || attention || pstate !== "open" ? [[{ label: tr("Wis filters", "Clear filters"), icon: "circle-x", onselect: clear }]] : []),
    ] };
  }
  function clear() { query = ""; attention = null; pstate = "open"; }

  // A held row: its link, and the Mac's quick actions (close and merge an open one, ready a draft, reopen a closed one).
  function down(e: PointerEvent, p: PullDigest) {
    held = false;
    const el = e.currentTarget as HTMLElement;
    press = setTimeout(() => { held = true; haptic("tap"); menu = { anchor: el.getBoundingClientRect(), sections: rowMenu(p) }; }, 450);
  }
  const up = () => clearTimeout(press);
  function rowMenu(p: PullDigest) {
    const out: MenuItem[][] = [[
      { label: tr("Kopieer link", "Copy link"), icon: "link", onselect: () => { navigator.clipboard?.writeText(p.url); } },
      { label: tr("Open in browser", "Open in browser"), icon: "globe", onselect: () => { window.open(p.url, "_blank"); } },
    ]];
    if (!canAct || !has(view, Feature.pullActions)) return out;
    const quick = p.state === "open" ? ["merge", "close"] : p.state === "draft" ? ["ready", "close"] : p.state === "closed" ? ["reopen"] : [];
    if (quick.length) out.push(quick.map((k) => ({ label: kindWord(k as PullAction["kind"]), icon: kindIcon(k as PullAction["kind"]), destructive: k === "close", onselect: () => { confirming = { kind: k as PullAction["kind"], pull: p }; } })));
    return out;
  }
  /** A row's quick action: the pull request read in full first, so it goes only at the head the Mac sees and when it offers it. */
  async function quick(p: PullDigest, kind: PullAction["kind"]) {
    const r = await companion.call({ op: "pull", item: p.url });
    took(r.view);
    const d = r.response?.pull;
    if (!d) { haptic("warning"); return; }
    let action: PullAction;
    if (kind === "merge") {
      if (d.blocker || !d.methods.length) { haptic("warning"); failedList = tr("Deze pull request kan nu niet vanaf je telefoon worden samengevoegd.", "This pull request cannot be merged from your phone now."); return; }
      action = { kind: "merge", method: d.methods[0], head: d.headSHA };
    } else {
      if (!d.actions?.includes(kind)) { haptic("warning"); failedList = tr("Je Mac biedt dit nu niet aan voor deze pull request.", "Your Mac does not offer this for this pull request now."); return; }
      action = { kind, head: d.headSHA };
    }
    const done = await companion.call({ op: "pullAct", item: p.url, pullAction: action });
    took(done.view);
    haptic(done.response ? "success" : "warning");
    loadList();
  }
  let failedList = $state<string | null>(null);

  const kindWord = (k: PullAction["kind"]) => ({
    merge: tr("Samenvoegen", "Merge"), close: tr("Sluiten", "Close"), reopen: tr("Heropenen", "Reopen"), ready: tr("Klaar voor review", "Ready for review"),
    draft: tr("Terug naar concept", "Convert to draft"), updateBranch: tr("Branch bijwerken", "Update branch"), rebaseBranch: tr("Branch rebasen", "Rebase branch"),
    autoMergeOff: tr("Auto-merge uitzetten", "Disable auto-merge"), autoMergeOn: tr("Auto-merge aanzetten", "Enable auto-merge"),
    rerunFailed: tr("Mislukte checks opnieuw", "Rerun failed checks"), deleteBranch: tr("Branch verwijderen", "Delete branch"),
  } as Record<string, string>)[k] ?? k;
  const kindIcon = (k: PullAction["kind"]) => ({
    merge: "git-merge", close: "circle-x", reopen: "rotate-ccw", ready: "git-pull-request", draft: "circle-dashed", updateBranch: "git-branch",
    rebaseBranch: "git-branch", autoMergeOff: "zap-off", autoMergeOn: "zap", rerunFailed: "refresh-cw", deleteBranch: "trash-2",
  } as Record<string, string>)[k] ?? "circle";
  const confirmTitle = (k: PullAction["kind"]) => ({
    merge: tr("Deze pull request samenvoegen?", "Merge this pull request?"), close: tr("Deze pull request sluiten?", "Close this pull request?"),
    ready: tr("Klaar voor review markeren?", "Mark ready for review?"), reopen: tr("Deze pull request heropenen?", "Reopen this pull request?"),
    deleteBranch: tr("De branch verwijderen?", "Delete the branch?"),
  } as Record<string, string>)[k] ?? kindWord(k);

  /** The Mac's action menu for the open pull request: the link, then what the Mac takes now. */
  function openMore(e: MouseEvent) {
    if (!detail) return;
    const d = detail;
    const anchor = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const plain = (["ready", "draft", "updateBranch", "rebaseBranch", "autoMergeOff", "rerunFailed", "reopen"] as PullAction["kind"][]).filter(allows);
    const risky = (["deleteBranch", "close"] as PullAction["kind"][]).filter(allows);
    menu = { anchor, sections: [
      [{ label: tr("Kopieer link", "Copy link"), icon: "link", onselect: () => navigator.clipboard?.writeText(d.url) },
       { label: tr("Open in browser", "Open in browser"), icon: "globe", onselect: () => window.open(d.url, "_blank") },
       { label: tr("Vernieuwen", "Refresh"), icon: "refresh-cw", onselect: () => loadDetail(d.url) }],
      [...plain.map((k) => ({ label: kindWord(k), icon: kindIcon(k), onselect: () => run({ kind: k }) })),
       ...(allows("autoMergeOn") ? d.methods.map((m) => ({ label: `${kindWord("autoMergeOn")}: ${methodWord(m)}`, icon: "zap", onselect: () => run({ kind: "autoMergeOn", method: m }) })) : [])],
      risky.map((k) => ({ label: kindWord(k), icon: kindIcon(k), destructive: true, onselect: () => (confirming = { kind: k }) })),
    ].filter((section) => section.length) };
  }
  async function run(action: PullAction) {
    const r = await act(action);
    if (r) { haptic("success"); if (["close", "reopen", "ready", "draft"].includes(action.kind)) loadList(); }
  }
  async function sendComment() {
    const words = comment.trim();
    if (!words) return;
    if (await act({ kind: "note", body: words })) { haptic("success"); comment = ""; }
  }
</script>

<div class="pulls">
  <div class="bar">
    {#if open}<button class="link" onclick={() => { open = null; detail = null; }}><Ico name="chevron-left" size={20} stroke={2.4} /></button>{:else}<button class="link" onclick={onclose}>{tr("Klaar", "Done")}</button>{/if}
    <span class="title">{#if open && detail}<strong>#{detail.number}</strong><small>{detail.repo}</small>{:else}<strong>{tr("Pull requests", "Pull requests")}</strong>{/if}</span>
    {#if open && detail}<button class="more" aria-label={tr("Meer", "More")} onclick={openMore}><Ico name="ellipsis" size={20} /></button>{:else}<span></span>{/if}
  </div>

  {#if !open}
    <div class="scroll">
      {#if list === null}<div class="spinner"></div>
      {:else if !list.length}
        <EmptyState icon="git-pull-request" title={tr("Geen pull requests", "No pull requests")} text={session ? tr("Aan deze sessie is nog geen pull request gekoppeld.", "This session has no pull request linked yet.") : tr("Pull requests van je accounts in Nook op je Mac verschijnen hier.", "Pull requests from your accounts in Nook on your Mac show up here.")} />
      {:else}
        {#if full}
          <div class="chips scrollx">
            {#each ATTENTIONS as a (a)}
              {#if counts[a] > 0 || attention === a}
                <button class="chip" class:on={attention === a} onclick={() => { haptic("tap"); attention = attention === a ? null : a; }}>{chipWord(a)}<span class="n">{counts[a]}</span></button>
              {/if}
            {/each}
          </div>
          <div class="searchrow">
            <SearchField bind:value={query} placeholder={tr("Zoek, of label:bug repo: author:", "Search, or label:bug repo: author:")} />
            <button class="filter" class:on={pstate !== "open"} aria-label={tr("Sorteren en filteren", "Sort and filter")} onclick={openFilters}><Ico name="arrow-up-down" size={16} /></button>
          </div>
          {#if pstate !== "open"}<small class="statenote">{stateTitle(pstate)}</small>{/if}
          {#if failedList}<Banner icon="triangle-alert" tint="var(--coral)">{failedList}</Banner>{/if}
          {#if !groups.length}
            <EmptyState icon="search" title={tr("Geen pull requests gevonden", "No pull requests match")} text={tr("Probeer andere woorden, of wis de filters.", "Try other words, or clear the filters.")} />
            <button class="act wide" onclick={clear}>{tr("Wis filters", "Clear filters")}</button>
          {/if}
        {/if}
        {#each groups as g (g.title)}
          {#if g.title}<h3>{g.title} <span>{g.rows.length}</span></h3>{/if}
          {#each g.rows as p (p.url)}
            {@const m = mark(p)}
            <button class="row press" onclick={() => !held && openPull(p.url)} onpointerdown={(e) => down(e, p)} onpointerup={up} onpointerleave={up} onpointercancel={up} oncontextmenu={(e) => e.preventDefault()}>
              <span class="mark" style:color={m.tint}><Ico name={m.icon} size={14} stroke={2.4} /></span>
              <span class="text"><strong>{p.title}</strong><small>{p.repo}#{p.number} · {p.author}{p.created ? ` · ${tr("geopend {t}", "opened {t}", { t: age(p.created) })}` : p.updated ? ` · ${relative(p.updated)}` : ""}</small>
                {#if (p.state === "open" || p.state === "draft") && reviewWord(p.review)}<small class="review" class:ok={p.review === "approved"} class:ask={p.review === "changesRequested"}>{reviewWord(p.review)}</small>{/if}
                {#if p.labels?.length}<span class="labels">{#each p.labels.slice(0, 3) as l (l)}<span class="label"><i style:background={p.labelColors?.[l] ? `#${p.labelColors[l]}` : "var(--text3)"}></i>{l}</span>{/each}{#if p.labels.length > 3}<small>+{p.labels.length - 3}</small>{/if}</span>{/if}
              </span>
              <span class="side">
                <span class="ci">{#if p.ci === "failing"}<span style:color="var(--coral)"><Ico name="circle-x" size={14} /></span>{:else if p.ci === "pending"}<span style:color="var(--amber)"><Ico name="clock" size={14} /></span>{:else if p.ci === "passing"}<span style:color="var(--mint)"><Ico name="circle-check" size={14} /></span>{/if}{#if p.checksTotal}<small>{p.checksPassed ?? 0}/{p.checksTotal}</small>{/if}</span>
                {#if p.comments}<small class="ci"><Ico name="message-square-text" size={12} />{p.comments}</small>{/if}
                {#if p.additions != null}<small><span class="add">+{p.additions}</span> <span class="del">−{p.deletions ?? 0}</span></small>{/if}
              </span>
            </button>
          {/each}
        {/each}
      {/if}
    </div>
  {:else if !detail}
    <div class="scroll"><div class="spinner"></div></div>
  {:else}
    {@const m = mark({ state: detail.state, conflict: detail.blocker === "conflict" })}
    <div class="scroll">
      <div class="headcard">
        <span class="hrow"><span style:color={m.tint}><Ico name={m.icon} size={14} stroke={2.4} /></span><span style:color={m.tint}>{stateWord(detail.state)}</span><span class="add">+{detail.additions}</span><span class="del">−{detail.deletions}</span></span>
        <strong>{detail.title}</strong>
        <small>{detail.author} · {detail.headBranch} → {detail.baseBranch}{detail.created ? ` · ${tr("geopend {t}", "opened {t}", { t: age(detail.created) })}` : ""}</small>
      </div>
      <div class="chips scrollx">
        {#each [["summary", tr("Samenvatting", "Summary"), 0], ...(rich ? [["conversation", tr("Gesprek", "Conversation"), (detail.conversation?.length ?? 0) + (detail.threads?.length ?? 0)]] : []), ["checks", tr("Checks", "Checks"), detail.checks.length], ["files", tr("Bestanden", "Files"), detail.files.length]] as [key, label, n] (key)}
          <button class="chip" class:on={segment === key} onclick={() => (segment = key as typeof segment)}>{label}{#if n}<span class="n">{n}</span>{/if}</button>
        {/each}
      </div>
      {#if segment === "summary"}
        {#if detail.blocker}<p class="blocker"><Ico name="triangle-alert" size={13} />{blockerText(detail.blocker)}</p>{/if}
        {#if rich && (detail.reviewers?.length || detail.assignees?.length || detail.labels?.length || detail.milestone || detail.issues?.length || detail.autoMerge || detail.behind)}
          <div class="side-info">
            {#if detail.reviewers?.length}<div><small>{tr("Reviewers", "Reviewers")}</small><span>{detail.reviewers.join(", ")}</span></div>{/if}
            {#if detail.assignees?.length}<div><small>{tr("Toegewezen aan", "Assignees")}</small><span>{detail.assignees.join(", ")}</span></div>{/if}
            {#if detail.labels?.length}<div><small>{tr("Labels", "Labels")}</small><span class="labels">{#each detail.labels as l (l)}<span class="label"><i style:background={detail.labelColors?.[l] ? `#${detail.labelColors[l]}` : "var(--text3)"}></i>{l}</span>{/each}</span></div>{/if}
            {#if detail.milestone}<div><small>{tr("Mijlpaal", "Milestone")}</small><span>{detail.milestone}</span></div>{/if}
            {#if detail.issues?.length}<div><small>{tr("Sluit", "Closes")}</small>{#each detail.issues as i (i.repo + i.number)}<button class="issue" disabled={!i.url} onclick={() => i.url && window.open(i.url, "_blank")}><span style:color={i.open ? "var(--mint)" : "var(--violet)"}><Ico name={i.open ? "circle-dashed" : "circle-check"} size={13} /></span>#{i.number} {i.title}</button>{/each}</div>{/if}
            {#if detail.autoMerge}<p class="verdict" style:color="var(--mint)"><Ico name="zap" size={13} />{detail.autoMerge.by ? tr("Auto-merge staat aan, door {by}", "Auto-merge is on, by {by}", { by: detail.autoMerge.by }) : tr("Auto-merge staat aan", "Auto-merge is on")}</p>{/if}
            {#if detail.behind}<p class="verdict behind"><Ico name="git-branch" size={13} />{tr("Achter op {base}", "Behind {base}", { base: detail.baseBranch })}{#if allows("updateBranch")}<button class="inline" onclick={() => run({ kind: "updateBranch" })}>{tr("Branch bijwerken", "Update branch")}</button>{/if}</p>{/if}
          </div>
        {/if}
        {#if detail.verdicts.length}
          {@const ok = detail.verdicts.filter((v) => v.approved).map((v) => v.author)}
          {@const no = detail.verdicts.filter((v) => !v.approved).map((v) => v.author)}
          {#if ok.length}<p class="verdict" style:color="var(--mint)"><Ico name="badge-check" size={13} />{tr("{a} keurde goed", "{a} approved", { a: ok.join(", ") })}</p>{/if}
          {#if no.length}<p class="verdict" style:color="var(--amber)"><Ico name="circle-alert" size={13} />{tr("{a} vroeg om wijzigingen", "{a} asked for changes", { a: no.join(", ") })}</p>{/if}
        {/if}
        {#if detail.body.trim()}<div class="markdown body" use:richContent={detail.body}>{@html renderMarkdown(detail.body)}</div>{:else}<p class="none">{tr("Geen beschrijving.", "No description.")}</p>{/if}
      {:else if segment === "conversation"}
        {@const threads = detail.threads ?? []}
        {@const resolved = threads.filter((t) => t.resolved).length}
        {#each detail.conversation ?? [] as n (n.id)}
          <div class="note-card">
            <span class="who"><strong>{n.author}</strong>{#if n.verdict === "APPROVED"}<small style:color="var(--mint)">{tr("keurde goed", "approved")}</small>{:else if n.verdict === "CHANGES_REQUESTED"}<small style:color="var(--amber)">{tr("vroeg om wijzigingen", "asked for changes")}</small>{:else if n.verdict}<small>{tr("reviewde", "reviewed")}</small>{/if}{#if n.date}<small class="when">{relative(n.date)}</small>{/if}</span>
            {#if n.body}<div class="markdown body" use:richContent={n.body}>{@html renderMarkdown(n.body)}</div>{/if}
          </div>
        {/each}
        {#if threads.length}
          <h3>{tr("Threads", "Threads")} <span>{threads.length - resolved}</span></h3>
          {#each threads.filter((t) => showResolved || !t.resolved) as t (t.id)}
            <div class="note-card thread" class:done={t.resolved}>
              <span class="who"><code>{t.path.split("/").pop()}{t.line ? `:${t.line}` : ""}</code>{#if t.resolved}<small style:color="var(--mint)">{tr("Opgelost", "Resolved")}</small>{/if}{#if t.outdated}<small>{tr("Verouderd", "Outdated")}</small>{/if}</span>
              {#each t.comments as c (c.id)}
                <span class="who"><strong>{c.author}</strong>{#if c.date}<small class="when">{relative(c.date)}</small>{/if}</span>
                <div class="markdown body" use:richContent={c.body}>{@html renderMarkdown(c.body)}</div>
              {/each}
              {#if canAct && rich}
                <span class="thread-acts">
                  {#if t.canReply && allows("reply")}<button onclick={() => (replying = { thread: t, text: "" })}><Ico name="reply" size={14} />{tr("Antwoord", "Reply")}</button>{/if}
                  {#if t.canResolve && allows(t.resolved ? "unresolve" : "resolve")}<button onclick={() => run({ kind: t.resolved ? "unresolve" : "resolve", thread: t.id })}><Ico name={t.resolved ? "rotate-ccw" : "circle-check"} size={14} />{t.resolved ? tr("Heropen", "Unresolve") : tr("Oplossen", "Resolve")}</button>{/if}
                </span>
              {/if}
            </div>
          {/each}
          {#if resolved}<button class="link-row" onclick={() => (showResolved = !showResolved)}>{showResolved ? tr("Verberg opgeloste threads", "Hide resolved threads") : tr("Toon {n} opgeloste threads", "Show {n} resolved threads", { n: resolved })}</button>{/if}
        {/if}
        {#if !(detail.conversation?.length) && !threads.length}<p class="none">{tr("Nog geen opmerkingen.", "No comments yet.")}</p>{/if}
        {#if allows("note")}
          <SessionComposer bind:value={comment} placeholder={tr("Voeg een opmerking toe", "Add a comment")} onsend={() => sendComment()} canSend={!!comment.trim()} />
        {/if}
      {:else if segment === "checks"}
        {#if allows("rerunFailed")}<button class="act wide" onclick={() => run({ kind: "rerunFailed" })}><Ico name="refresh-cw" size={15} />{tr("Mislukte checks opnieuw", "Rerun failed checks")}</button>{/if}
        {#each detail.checks as c (c.name + c.detail)}
          <div class="check">
            <span style:color={c.outcome === "failure" || c.outcome === "failing" ? "var(--coral)" : c.outcome === "pending" ? "var(--amber)" : "var(--mint)"}><Ico name={c.outcome === "failure" || c.outcome === "failing" ? "circle-x" : c.outcome === "pending" ? "clock" : "circle-check"} size={14} /></span>
            <span class="text"><strong>{c.name}</strong>{#if c.detail}<small>{c.detail}</small>{/if}</span>
          </div>
        {:else}<p class="none">{tr("Geen checks op deze kop.", "No checks on this head.")}</p>{/each}
      {:else}
        <p class="viewed">{tr("{x} van {n} bekeken", "{x} of {n} viewed", { x: viewedCount, n: detail.files.length })}</p>
        {#each detail.files as f (f.path)}
          {@const mine = notes.filter((n) => n.path === f.path).length}
          <FileCard path={f.path} kind={f.status} added={f.additions} removed={f.deletions} patch={f.patch} truncated={f.truncated}
            oncomment={detail.lineComments && canAct ? (from, to, lines) => (asking = { path: f.path, lines, from, to, note: "" }) : undefined}>
            {#snippet extra()}
              <div class="fextra">
                {#if canAct}
                  <button class="viewbtn" aria-label={f.viewed === "viewed" ? tr("Markeer als niet bekeken", "Mark as not viewed") : tr("Markeer als bekeken", "Mark as viewed")}
                    onclick={() => act({ kind: f.viewed === "viewed" ? "unviewed" : "viewed", path: f.path })}
                    style:color={f.viewed === "viewed" ? "var(--mint)" : "var(--text3)"}><Ico name={f.viewed === "viewed" ? "circle-check" : "circle"} size={18} /></button>
                {/if}
                {#if f.viewed === "changed"}<small style:color="var(--amber)">{tr("Gewijzigd sinds bekeken", "Changed since viewed")}</small>{/if}
                {#if mine}<small style:color="var(--iris)">{mine === 1 ? tr("1 opmerking", "1 comment") : tr("{n} opmerkingen", "{n} comments", { n: mine })}</small>{/if}
              </div>
            {/snippet}
          </FileCard>
        {/each}
      {/if}
      {#if failed}<Banner icon="triangle-alert" tint="var(--coral)">{failed}</Banner>{/if}
    </div>
    <div class="actions">
      {#if !may(view, "operate")}
        <p class="actnote">{tr("Reviewen en samenvoegen staan voor deze iPhone uit in Nook op je Mac.", "Reviewing and merging are turned off for this phone in Nook on your Mac.")}</p>
      {:else if view.phase !== "connected"}
        <p class="actnote">{tr("Verbind met je Mac om te reviewen of samen te voegen.", "Connect to your Mac to review or merge.")}</p>
      {:else}
        <button class="act" onclick={() => (sheet = "review")}><Ico name="message-square-text" size={15} />{notes.length ? tr("Review ({n})", "Review ({n})", { n: notes.length }) : tr("Review", "Review")}</button>
        <button class="act" onclick={openWork}><Ico name="hammer" size={15} />{tr("Hieraan werken", "Work on this")}</button>
        {#if detail.autoMerge}
          <span class="act auto"><Ico name="zap" size={15} />{tr("Auto-merge aan", "Auto-merge on")}</span>
        {:else if (!detail.blocker && detail.methods.length) || allows("autoMergeOn")}
          <button class="act primary" onclick={(e) => (menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections: [
            ...(!detail!.blocker ? [detail!.methods.map((m) => ({ label: methodWord(m), icon: "git-merge", onselect: () => { confirmMerge = true; mergeMethod = m; } }))] : []),
            ...(allows("autoMergeOn") ? [detail!.methods.map((m) => ({ label: `${kindWord("autoMergeOn")}: ${methodWord(m)}`, icon: "zap", onselect: () => run({ kind: "autoMergeOn", method: m }) }))] : []),
          ] })}><Ico name="git-merge" size={15} />{tr("Samenvoegen", "Merge")}</button>
        {/if}
      {/if}
    </div>
  {/if}
</div>

{#if sheet === "review" && detail}
  <div class="subsheet">
    <div class="bar"><button class="link" onclick={() => (sheet = null)}>{tr("Annuleer", "Cancel")}</button><span class="title"><strong>{tr("Review", "Review")}</strong></span><span></span></div>
    <div class="scroll">
      <div class="segments">
        {#each [["comment", tr("Commentaar", "Comment")], ["approve", tr("Keur goed", "Approve")], ["requestChanges", tr("Vraag wijzigingen", "Request changes")]] as [key, label] (key)}
          <button class:on={verdict === key} disabled={key !== "comment" && !detail.verdictsAllowed} onclick={() => (verdict = key as typeof verdict)}>{label}</button>
        {/each}
      </div>
      <SessionComposer bind:value={words} placeholder={tr("Je review", "Your review")} minHeight={88} onsend={() => sendReview()} canSend={verdict === "approve" || !!words.trim() || notes.length > 0} />
      {#if verdict === "approve" && !words.trim()}<button class="act primary wide" onclick={sendReview}>{tr("Keur goed", "Approve")}</button>{/if}
      {#if notes.length}
        <h3>{tr("Opmerkingen bij regels", "Comments on lines")}</h3>
        {#each notes as n, i (i)}
          <div class="note"><span class="text"><strong>{n.path}:{n.line}</strong><small>{n.body}</small></span><button class="trash" aria-label={tr("Verwijder opmerking", "Remove comment")} onclick={() => (notes = notes.filter((_, j) => j !== i))}><Ico name="trash-2" size={15} /></button></div>
        {/each}
      {/if}
      <p class="foot">{tr("De review gaat vanaf je Mac met zijn account naar de forge, alleen op de kop die je nu ziet.", "The review goes to the forge from your Mac, with its account, only at the head you see now.")}</p>
    </div>
  </div>
{:else if sheet === "work" && detail}
  <div class="subsheet">
    <div class="bar"><button class="link" onclick={() => (sheet = null)}>{tr("Annuleer", "Cancel")}</button><span class="title"><strong>{tr("Hieraan werken", "Work on this")}</strong></span><span></span></div>
    <div class="scroll">
      {#if !options}<div class="spinner"></div>
      {:else}
        {@const chosen = options.agents.find((a) => a.id === agent)}
        <SessionComposer bind:value={task} placeholder={tr("Wat moet de agent doen? (leeg: leer het kennen)", "What should the agent do? (empty: get to know it)")} minHeight={88} onsend={startWork} canSend>
          {#snippet controls()}
            <ComposerPill label={chosen?.name ?? ""} onclick={(e) => (menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections: [options!.agents.map((a) => ({ label: a.name, checked: a.id === agent, onselect: () => { agent = a.id; model = a.defaultModel ?? ""; } }))] })}>
              {#snippet lead()}<AgentMark agent={chosen?.name ?? ""} size={16} />{/snippet}
            </ComposerPill>
            {#if (chosen?.models?.length ?? 0) > 1}
              <ComposerPill label={chosen?.models?.find((m) => m.id === model)?.name ?? tr("Standaardmodel", "Default model")} icon="cpu" onclick={(e) => (menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections: [chosen!.models!.map((m) => ({ label: m.name, checked: m.id === model, onselect: () => (model = m.id) }))] })} />
            {/if}
          {/snippet}
        </SessionComposer>
        {#if !task.trim()}<button class="act primary wide" onclick={() => startWork("")}>{tr("Start", "Start")}</button>{/if}
        <p class="foot">{tr("Nook haalt {branch} uit in een eigen worktree, waar je Mac {repo} heeft, en start daar de agent. Het vraagt eerst bij alles wat riskant is, zoals elke sessie vanaf je iPhone.", "Nook checks out {branch} in a worktree of its own, where your Mac has {repo}, and starts the agent there. It asks before anything risky, as every session started from your phone.", { branch: detail.headBranch, repo: detail.repo })}</p>
      {/if}
    </div>
  </div>
{/if}

{#if asking}
  {@const a = asking}
  <Dialog title={tr("Commentaar op deze regels", "Comment on these lines")} message={tr("Het wacht bij je review en gaat mee als je die verstuurt.", "It waits with your review and goes when you send it.")} bind:field={a.note} placeholder={tr("Je opmerking", "Your comment")} onclose={() => (asking = null)} buttons={[
    { label: tr("Aan review toevoegen", "Add to review"), bold: true, onselect: () => { const c = a.note.trim() && lineComment(a.path, a.from, a.to, positions(a.lines), a.note.trim()); if (c) { haptic("success"); notes = [...notes, c]; } } },
    { label: tr("Annuleer", "Cancel"), onselect: () => {} },
  ]} />
{/if}
{#if confirmMerge && detail}
  <Dialog title={tr("Deze pull request samenvoegen?", "Merge this pull request?")} message={tr("{head} in {base}, op de kop die je nu ziet.", "{head} into {base}, at the head you see now.", { head: detail.headBranch, base: detail.baseBranch })} onclose={() => (confirmMerge = false)} buttons={[
    { label: methodWord(mergeMethod), bold: true, onselect: () => merge(mergeMethod) },
    { label: tr("Annuleer", "Cancel"), onselect: () => {} },
  ]} />
{/if}
{#if confirming}
  {@const c = confirming}
  <Dialog title={confirmTitle(c.kind)} message={c.pull ? `${c.pull.repo}#${c.pull.number} · ${c.pull.title}` : c.kind === "deleteBranch" ? tr("De branch {b} wordt uit de repository verwijderd.", "The branch {b} is deleted from the repository.", { b: detail?.headBranch ?? "" }) : tr("Je kunt hem later heropenen.", "You can reopen it later.")} onclose={() => (confirming = null)} buttons={[
    { label: kindWord(c.kind), bold: true, destructive: c.kind === "close" || c.kind === "deleteBranch", onselect: () => (c.pull ? quick(c.pull, c.kind) : run({ kind: c.kind })) },
    { label: tr("Annuleer", "Cancel"), onselect: () => {} },
  ]} />
{/if}
{#if replying}
  {@const rp = replying}
  <Dialog title={tr("Antwoord", "Reply")} message={`${rp.thread.path}${rp.thread.line ? `:${rp.thread.line}` : ""}`} bind:field={rp.text} placeholder={tr("Je antwoord", "Your reply")} onclose={() => (replying = null)} buttons={[
    { label: tr("Stuur", "Send"), bold: true, onselect: () => { const words = rp.text.trim(); if (words) run({ kind: "reply", body: words, thread: rp.thread.id }); } },
    { label: tr("Annuleer", "Cancel"), onselect: () => {} },
  ]} />
{/if}
{#if menu}<Menu sections={menu.sections} anchor={menu.anchor} onclose={() => (menu = null)} />{/if}

<style>
  .pulls { flex: 1; min-height: 0; display: flex; flex-direction: column; padding-top: 10px; }
  .bar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 8px 16px; min-height: 44px; }
  .link { justify-self: start; font: 400 17px var(--font) !important; color: var(--paper) !important; display: inline-flex; align-items: center; }
  .title { display: flex; flex-direction: column; align-items: center; }
  .title strong { font: 600 17px var(--font); }
  .title small { font: var(--pt-caption); color: var(--text3); }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 8px; }
  h3 { margin: 8px 0 0; font: var(--pt-label); color: var(--text3); }
  h3 span { font: var(--pt-caption); }
  .more { justify-self: end; width: 44px; height: 44px; display: inline-flex; align-items: center; justify-content: center; color: var(--paper) !important; }
  .chips { display: flex; gap: 6px; }
  .scrollx { overflow-x: auto; scrollbar-width: none; flex: none; }
  .chip { flex: none; height: 32px; padding: 0 12px; border-radius: 8px; background: var(--smoke) !important; color: var(--text-strong) !important; font: var(--pt-label) !important; display: inline-flex; align-items: center; gap: 6px; }
  .chip.on { background: var(--iris) !important; color: var(--on-iris) !important; }
  .chip .n { opacity: 0.7; font-variant-numeric: tabular-nums; }
  .searchrow { display: flex; gap: 6px; align-items: center; }
  .searchrow :global(.search) { flex: 1; }
  .filter { width: 44px; height: 38px; display: inline-flex; align-items: center; justify-content: center; color: var(--text2) !important; }
  .filter.on { color: var(--iris) !important; }
  .statenote { font: var(--pt-caption); color: var(--text3); }
  .review { color: var(--text3); }
  .review.ok { color: var(--mint) !important; }
  .review.ask { color: var(--amber) !important; }
  .labels { display: flex; flex-wrap: wrap; gap: 4px; align-items: center; }
  .label { display: inline-flex; align-items: center; gap: 4px; padding: 0 6px; border: 1px solid var(--line2); border-radius: 6px; font: var(--pt-caption); color: var(--text2); }
  .label i { width: 7px; height: 7px; border-radius: 50%; display: inline-block; }
  .ci { display: inline-flex; align-items: center; gap: 3px; color: var(--text3); font-variant-numeric: tabular-nums; }
  .side-info { display: flex; flex-direction: column; gap: 10px; padding: 12px; background: var(--surface); border: 1px solid var(--line2); border-radius: 12px; }
  .side-info > div { display: flex; flex-direction: column; gap: 2px; }
  .side-info small { font: var(--pt-caption); color: var(--text3); }
  .side-info span { font: var(--pt-detail); color: var(--paper); }
  .issue { text-align: left; font: var(--pt-detail) !important; color: var(--paper) !important; display: flex; gap: 6px; align-items: baseline; min-height: 32px; }
  .behind { color: var(--amber); flex-wrap: wrap; }
  .inline { margin-left: auto; min-height: 44px; font: var(--pt-label) !important; color: var(--paper) !important; }
  .note-card { display: flex; flex-direction: column; gap: 6px; padding: 12px; background: var(--surface); border-radius: 12px; }
  .note-card.done { opacity: 0.7; }
  .who { display: flex; align-items: baseline; gap: 8px; }
  .who strong { font: var(--pt-strong); color: var(--paper); }
  .who small { font: var(--pt-caption); color: var(--text3); }
  .who .when { margin-left: auto; }
  .who code { font: var(--pt-code); color: var(--text2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .thread-acts { display: flex; gap: 16px; }
  .thread-acts button { min-height: 44px; display: inline-flex; align-items: center; gap: 6px; font: var(--pt-label) !important; color: var(--paper) !important; }
  .link-row { min-height: 44px; font: var(--pt-label) !important; color: var(--text2) !important; }
  .act.auto { flex: none; padding: 0 14px; color: var(--mint) !important; background: transparent !important; }
  .row { display: flex; align-items: flex-start; gap: 8px; padding: 12px; background: var(--field) !important; border-radius: 12px; text-align: left; }
  .mark { width: 22px; display: inline-flex; justify-content: center; padding-top: 2px; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .text strong { font: var(--pt-strong); color: var(--paper); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .text small { font: var(--pt-caption); color: var(--text3); }
  .side { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; font-variant-numeric: tabular-nums; }
  .add { color: var(--mint); font: var(--pt-code); font-size: 12px; }
  .del { color: var(--coral); font: var(--pt-code); font-size: 12px; }
  .headcard { display: flex; flex-direction: column; gap: 6px; padding: 12px; background: var(--surface); border: 1px solid var(--line2); border-radius: 12px; }
  .hrow { display: flex; align-items: center; gap: 8px; font: var(--pt-label); }
  .headcard strong { font: var(--pt-title); color: var(--paper); }
  .headcard small { font: var(--pt-caption); color: var(--text3); }
  .segments { display: flex; padding: 2px; background: var(--well); border-radius: 9px; }
  .segments button { flex: 1; height: 30px; border-radius: 7px; font: var(--pt-label) !important; color: var(--text2) !important; }
  .segments button.on { background: var(--smoke) !important; color: var(--paper) !important; }
  .blocker, .verdict { margin: 0; display: flex; align-items: baseline; gap: 6px; font: var(--pt-detail); color: var(--amber); }
  .body { font: var(--pt-body); color: var(--text-strong); }
  .none { margin: 0; font: var(--pt-body); color: var(--text2); }
  .check { display: flex; gap: 8px; padding: 10px 12px; background: var(--surface); border-radius: 10px; }
  .viewed { margin: 0; font: var(--pt-label); color: var(--text2); }
  .fextra { display: flex; align-items: center; gap: 8px; padding: 0 12px 8px; }
  .fextra:empty { display: none; }
  .viewbtn { width: 28px; height: 28px; display: inline-flex; align-items: center; justify-content: center; }
  .actions { display: flex; gap: 8px; padding: 8px 16px calc(8px + var(--safe-bottom, 0px)); background: rgba(0, 0, 0, 0.96); border-top: 0.5px solid var(--hairline); }
  .act { flex: 1; height: 44px; border-radius: 999px; background: var(--smoke) !important; color: var(--paper) !important; font: 600 14px var(--font) !important; display: inline-flex; align-items: center; justify-content: center; gap: 6px; }
  .act.primary { background: var(--iris) !important; color: var(--on-iris) !important; }
  .act.wide { flex: none; width: 100%; }
  .actnote { margin: 0; flex: 1; font: var(--pt-detail); color: var(--text2); text-align: center; }
  .subsheet { position: fixed; inset: 0; z-index: 45; background: var(--canvas); display: flex; flex-direction: column; padding-top: calc(var(--safe-top, 0px) + 10px); animation: up 300ms cubic-bezier(0.2, 0.9, 0.25, 1); }
  .note { display: flex; align-items: center; gap: 8px; padding: 10px 12px; background: var(--surface); border-radius: 10px; }
  .trash { color: var(--coral) !important; width: 32px; height: 32px; display: inline-flex; align-items: center; justify-content: center; }
  .foot { margin: 0; font: var(--pt-detail); color: var(--text3); }
  .spinner { margin: 60px auto; width: 26px; height: 26px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @keyframes up { from { transform: translateY(100%); } }
</style>
