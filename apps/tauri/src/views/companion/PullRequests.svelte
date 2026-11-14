<script lang="ts">
  // Pull requests, as the iPhone's sheet (`PullRequestListView`, `PullRequestDetailView`): the Mac's list (yours, for
  // your review, watched) or a session's linked ones, and one in full with its summary, checks and files. Pick lines in
  // a file to comment, mark files viewed, then send one review; Merge as the forge allows; Work on this starts a session
  // on its branch. The Mac acts with its own accounts, only at the head you saw, and refuses what its page would.
  import { onMount } from "svelte";
  import { companion, has, may, relative, Feature, type ClientView, type LineComment, type PullDetail, type PullDigest, type LaunchOptions } from "../../lib/companion";
  import { lineComment, positions } from "../../lib/patch";
  import { renderMarkdown } from "../../lib/markdown";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import Ico from "./ui/Ico.svelte";
  import FileCard from "./ui/FileCard.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Dialog from "./ui/Dialog.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ComposerPill from "./ui/ComposerPill.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import Banner from "./ui/Banner.svelte";

  let { view, session, onclose, took, onstarted }: { view: ClientView; session?: string; onclose: () => void; took: (v: ClientView) => void; onstarted: (id: string) => void } = $props();

  let list = $state<PullDigest[] | null>(null);
  let open = $state<string | null>(null);
  let detail = $state<PullDetail | null>(null);
  let segment = $state<"summary" | "checks" | "files">("summary");
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

  async function act(action: Parameters<typeof companion.call>[0]["pullAction"]) {
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

  const groups = $derived.by(() => {
    const all = list ?? [];
    if (session) return [{ title: "", rows: all }];
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
</script>

<div class="pulls">
  <div class="bar">
    {#if open}<button class="link" onclick={() => { open = null; detail = null; }}><Ico name="chevron-left" size={20} stroke={2.4} /></button>{:else}<button class="link" onclick={onclose}>{tr("Klaar", "Done")}</button>{/if}
    <span class="title">{#if open && detail}<strong>#{detail.number}</strong><small>{detail.repo}</small>{:else}<strong>{tr("Pull requests", "Pull requests")}</strong>{/if}</span>
    <span></span>
  </div>

  {#if !open}
    <div class="scroll">
      {#if list === null}<div class="spinner"></div>
      {:else if !list.length}
        <EmptyState icon="git-pull-request" title={tr("Geen pull requests", "No pull requests")} text={session ? tr("Aan deze sessie is nog geen pull request gekoppeld.", "This session has no pull request linked yet.") : tr("Pull requests van je accounts in Nook op je Mac verschijnen hier.", "Pull requests from your accounts in Nook on your Mac show up here.")} />
      {:else}
        {#each groups as g (g.title)}
          {#if g.title}<h3>{g.title} <span>{g.rows.length}</span></h3>{/if}
          {#each g.rows as p (p.url)}
            {@const m = mark(p)}
            <button class="row press" onclick={() => openPull(p.url)}>
              <span class="mark" style:color={m.tint}><Ico name={m.icon} size={14} stroke={2.4} /></span>
              <span class="text"><strong>{p.title}</strong><small>{p.repo}#{p.number} · {p.author}{p.updated ? ` · ${relative(p.updated)}` : ""}</small></span>
              <span class="side">
                {#if p.ci === "failing"}<span style:color="var(--coral)"><Ico name="circle-x" size={14} /></span>{:else if p.ci === "pending"}<span style:color="var(--amber)"><Ico name="clock" size={14} /></span>{:else if p.ci === "passing"}<span style:color="var(--mint)"><Ico name="circle-check" size={14} /></span>{/if}
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
        <small>{detail.author} · {detail.headBranch} → {detail.baseBranch}</small>
      </div>
      <div class="segments">
        {#each [["summary", tr("Samenvatting", "Summary")], ["checks", tr("Checks {n}", "Checks {n}", { n: detail.checks.length })], ["files", tr("Bestanden {n}", "Files {n}", { n: detail.files.length })]] as [key, label] (key)}
          <button class:on={segment === key} onclick={() => (segment = key as typeof segment)}>{label}</button>
        {/each}
      </div>
      {#if segment === "summary"}
        {#if detail.blocker}<p class="blocker"><Ico name="triangle-alert" size={13} />{blockerText(detail.blocker)}</p>{/if}
        {#if detail.verdicts.length}
          {@const ok = detail.verdicts.filter((v) => v.approved).map((v) => v.author)}
          {@const no = detail.verdicts.filter((v) => !v.approved).map((v) => v.author)}
          {#if ok.length}<p class="verdict" style:color="var(--mint)"><Ico name="badge-check" size={13} />{tr("{a} keurde goed", "{a} approved", { a: ok.join(", ") })}</p>{/if}
          {#if no.length}<p class="verdict" style:color="var(--amber)"><Ico name="circle-alert" size={13} />{tr("{a} vroeg om wijzigingen", "{a} asked for changes", { a: no.join(", ") })}</p>{/if}
        {/if}
        {#if detail.body.trim()}<div class="markdown body">{@html renderMarkdown(detail.body)}</div>{:else}<p class="none">{tr("Geen beschrijving.", "No description.")}</p>{/if}
      {:else if segment === "checks"}
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
        {#if !detail.blocker && detail.methods.length}
          <button class="act primary" onclick={(e) => (menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections: [detail!.methods.map((m) => ({ label: methodWord(m), icon: "git-merge", onselect: () => { confirmMerge = true; mergeMethod = m; } }))] })}><Ico name="git-merge" size={15} />{tr("Samenvoegen", "Merge")}</button>
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
