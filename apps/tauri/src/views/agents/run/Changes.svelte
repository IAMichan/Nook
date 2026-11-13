<script lang="ts">
  // De wijzigingen van een sessie (`ChangesViews` en `GitQuickButton` op de Mac): de boom met gewijzigde bestanden, de
  // diff van het gekozen bestand, en de ene git-knop (commit, push, pull request of pull, wat er nu past). Alles
  // gebeurt pas na jouw klik; pushen naar de standaardbranch vraagt eerst of je dat echt wilt.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { agents } from "../../../lib/agents.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { isActive, workspaceApi, type FileChange, type GitView, type QuickAction, type QuickView, type TreeRow, type WorkspaceRun } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import UnifiedDiffView from "../UnifiedDiffView.svelte";

  let { run, file = null, onclose }: { run: WorkspaceRun; file?: string | null; onclose: () => void } = $props();

  let view = $state<GitView | null>(null);
  let quick = $state<QuickView | null>(null);
  let selected = $state<string | null>(null);
  let diff = $state<string | null>(null);
  let diffError = $state<string | null>(null);
  let collapsed = $state(new Set<string>());
  let busy = $state<string | null>(null);
  let error = $state<string | null>(null);
  let done = $state<string | null>(null);
  // De actie die nu loopt: die van de knop, of de andere weg ("Nieuwe branch en PR").
  let chosen = $state<QuickAction | null>(null);
  // Formulieren: commit, bevestigen van de standaardbranch, pull request.
  let form = $state<"" | "commit" | "confirmDefault" | "pr">("");
  let subject = $state("");
  let body = $state("");
  let pr = $state({ title: "", body: "", head: "", base: "", draft: false });

  const active = $derived(isActive(run.status));
  const files = $derived(view?.snapshot?.status?.files ?? []);
  const fileFor = (path: string): FileChange | undefined => files.find((f) => f.path === path);

  // The parent hands a new `run` object on every workspace update; these deriveds only change with the values themselves,
  // so the effects below do not read git again for an update that changed nothing here.
  const runId = $derived(run.id);
  const changedKey = $derived(`${run.changedFiles}|${run.updatedAt}`);
  let reread: ReturnType<typeof setTimeout> | undefined;

  async function load(refresh: boolean) {
    const id = runId;
    try {
      view = await workspaceApi.git(id, refresh);
      // Een bestand dat niet meer gewijzigd is (na een commit), heeft geen diff meer.
      if (selected && !(view.snapshot?.status?.files ?? []).some((f) => f.path === selected)) {
        selected = null;
        diff = null;
      }
      if (refresh) {
        clearTimeout(reread);
        reread = setTimeout(() => load(false), 600);
      }
    } catch (e) {
      error = String(e);
    }
    try {
      quick = await workspaceApi.quick(id);
    } catch (e) {
      quick = null;
      error = String(e);
    }
  }

  $effect(() => {
    void runId;
    load(true);
    return () => clearTimeout(reread);
  });

  // De git-stand veranderde (na een beurt, commit of push): opnieuw lezen.
  $effect(() => {
    void changedKey;
    load(false);
  });

  $effect(() => {
    if (file && !selected) {
      const match = files.find((f) => f.path === file || file?.endsWith("/" + f.path));
      if (match) select(match.path);
    } else if (!selected && files.length) {
      select(files[0].path);
    }
  });

  async function select(path: string) {
    selected = path;
    diff = null;
    diffError = null;
    const f = fileFor(path);
    if (!f) return;
    try {
      diff = await workspaceApi.diff(run.id, f);
    } catch (e) {
      diffError = String(e);
    }
  }

  function toggleFolder(path: string) {
    const next = new Set(collapsed);
    if (next.has(path)) next.delete(path);
    else next.add(path);
    collapsed = next;
  }

  function visible(row: TreeRow): boolean {
    for (const c of collapsed) if (row.path !== c && row.path.startsWith(c + "/")) return false;
    return true;
  }

  const letters: Record<string, string> = { added: "A", modified: "M", deleted: "D", renamed: "R", copied: "C", untracked: "U", conflicted: "!", typeChanged: "T" };

  async function step(label: string, f: () => Promise<unknown>): Promise<boolean> {
    busy = label;
    error = null;
    try {
      await f();
      return true;
    } catch (e) {
      error = String(e);
      return false;
    } finally {
      busy = null;
      workspace.refresh();
    }
  }

  const label = (action: QuickAction) => (action.startsWith("branch") ? tr("Nieuwe branch en PR", "New branch and PR") : (quick?.label ?? "Git"));

  /// De knop: committen vraagt eerst het bericht, pushen naar de standaardbranch een bevestiging, een PR het formulier.
  /// Een nieuwe branch landt nooit op de standaardbranch en vraagt dus geen bevestiging.
  function quickClick(action: QuickAction | null = quick?.action ?? null) {
    if (!action || !quick) return;
    chosen = action;
    done = null;
    if (action.startsWith("commit") || action === "branchCommitPushPr") {
      subject = subject || run.title;
      form = "commit";
    } else if (quick.state.isDefaultBranch && action === "push") {
      form = "confirmDefault";
    } else if (action === "pull") {
      step(tr("Pullen…", "Pulling…"), () => workspaceApi.pull(run.id)).then(() => load(false));
    } else if (action === "branchPushPr") {
      newBranch(run.title).then((ok) => { if (ok) continueAfterCommit(); });
    } else {
      continueAfterCommit();
    }
  }

  /// Een nieuwe branch voor de nieuwe pull request; het snijpunt houdt de commits van de vorige erbuiten.
  let cut: string | null = null;
  async function newBranch(topic: string): Promise<boolean> {
    return step(tr("Nieuwe branch starten…", "Starting new branch…"), async () => {
      const started = await workspaceApi.startBranch(run.id, topic);
      cut = started.cut;
      done = tr("Nieuwe branch: {branch}", "New branch: {branch}", { branch: started.branch });
    });
  }

  async function commit() {
    if (!subject.trim()) return;
    const action = chosen;
    if (action === "branchCommitPushPr" && !(await newBranch(subject))) return;
    const ok = await step(tr("Committen…", "Committing…"), async () => {
      const sha = await workspaceApi.commitAll(run.id, subject, body);
      done = tr("Gecommit als {sha}", "Committed as {sha}", { sha });
    });
    form = "";
    if (!ok) return;
    subject = "";
    body = "";
    if (action === "commitPush" || action === "commitPushPr" || action === "branchCommitPushPr") {
      if (quick?.state.isDefaultBranch && action !== "branchCommitPushPr") form = "confirmDefault";
      else await continueAfterCommit();
    }
    load(false);
  }

  async function push(): Promise<boolean> {
    return step(tr("Pushen…", "Pushing…"), async () => {
      const branch = await workspaceApi.push(run.id);
      done = tr("Gepusht: {branch}", "Pushed: {branch}", { branch });
    });
  }

  async function continueAfterCommit() {
    form = "";
    const action = chosen ?? quick?.action;
    if (cut) {
      const from = cut;
      cut = null;
      await step(tr("Op de basis zetten…", "Moving onto the base…"), () => workspaceApi.moveOntoBase(run.id, from));
    }
    const pushes = action && action !== "commit" && action !== "pull" && action !== "createPr";
    if (pushes && !(await push())) return;
    if (action === "commitPushPr" || action === "pushPr" || action === "createPr" || action?.startsWith("branch")) await openPrForm();
    load(false);
  }

  async function openPrForm() {
    const base = quick?.base ?? run.baseBranch?.replace(/^origin\//, "") ?? "main";
    try {
      const d = await workspaceApi.pullRequestDraft(run.id, base);
      pr = { ...d, draft: false };
      form = "pr";
    } catch (e) {
      error = String(e);
    }
  }

  async function createPr() {
    await step(tr("Pull request openen…", "Opening pull request…"), async () => {
      const r = await workspaceApi.createPullRequest(run.id, pr);
      form = "";
      if (r.created) {
        done = tr("Pull request gemaakt", "Pull request created");
        agents.confirm(tr("Pull request gemaakt", "Pull request created"));
      }
      await openUrl(r.url);
    });
    load(false);
  }
</script>

<div class="changes">
  <div class="top">
    <strong>{tr("Wijzigingen", "Changes")}</strong>
    <span class="faint small">{run.branch ? tr("Op {branch}", "On {branch}", { branch: run.branch }) : ""}{view?.snapshot?.status ? " · " + tr("{n} bestanden", "{n} files", { n: files.length }) : ""}</span>
    <span class="spacer"></span>
    {#if quick?.pullRequest}<button class="ghost" onclick={() => openUrl(quick!.pullRequest!)}>{tr("Bekijk PR", "View PR")}</button>{/if}
    <button class="primary" disabled={!quick?.action || active || !!busy}
      title={quick?.reason ?? tr("Wat de knop doet hangt af van de branch: committen, pushen, een pull request maken of pullen.", "What the button does depends on the branch: commit, push, create a pull request or pull.")} onclick={() => quickClick()}>
      {busy ?? quick?.label ?? "Git"}
    </button>
    {#each quick?.alternatives ?? [] as other}
      <button class="ghost" disabled={active || !!busy} title={tr("Zet deze wijzigingen op een nieuwe branch met een eigen pull request.", "Put these changes on a new branch with its own pull request.")} onclick={() => quickClick(other)}>{label(other)}</button>
    {/each}
    <button class="ghost" title={tr("Opnieuw lezen", "Reload")} onclick={() => load(true)}>↻</button>
    <button class="ghost" onclick={onclose}>{tr("Sluit", "Close")}</button>
  </div>
  {#if quick && !quick.action && quick.reason}<p class="faint small">{quick.reason}</p>{/if}
  {#if quick?.action && quick.destination && !busy}<p class="faint small">{quick.destination}</p>{/if}
  {#if active}<p class="faint small">{tr("De agent werkt nog; committen en pushen kan als hij klaar is.", "The agent is still working; you can commit and push once it's done.")}</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}
  {#if done}<p class="ok">{done}</p>{/if}

  {#if form === "commit"}
    <div class="form">
      <div class="faint small">{chosen === "branchCommitPushPr"
        ? tr("Op een nieuwe branch (vanaf {branch}) in {dir}, met een eigen pull request.", "On a new branch (from {branch}) in {dir}, with its own pull request.", { branch: quick?.state.branch ?? "?", dir: run.workingDirectory })
        : tr("Op {branch} in {dir}. Er wordt alleen gecommit; pushen doet de knop daarna.", "On {branch} in {dir}. This only commits; the button pushes afterwards.", { branch: quick?.state.branch ?? "?", dir: run.workingDirectory })}</div>
      <input bind:value={subject} placeholder={tr("Bericht", "Message")} />
      <textarea bind:value={body} rows="3" placeholder={tr("Toelichting (optioneel)", "Description (optional)")}></textarea>
      <div class="row"><button class="ghost" onclick={() => (subject = run.title)}>{tr("Gebruik de naam van de sessie", "Use the session's name")}</button><span class="spacer"></span>
        <button class="ghost" onclick={() => (form = "")}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={!subject.trim() || !!busy} onclick={commit}>{tr("Commit {n} bestanden", "Commit {n} files", { n: files.length })}</button></div>
    </div>
  {:else if form === "confirmDefault"}
    <div class="form warn">
      <strong>{tr("Naar {branch} pushen?", "Push to {branch}?", { branch: quick?.state.branch ?? "" })}</strong>
      <span class="faint small">{tr("Dit is de standaardbranch. De wijzigingen gaan meteen naar {branch} op de remote.", "This is the default branch. The changes go straight to {branch} on the remote.", { branch: quick?.state.branch ?? "" })}</span>
      <div class="row"><span class="spacer"></span><button class="ghost" onclick={() => (form = "")}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" onclick={async () => { form = ""; await push(); load(false); }}>{tr("Toch pushen", "Push anyway")}</button></div>
    </div>
  {:else if form === "pr"}
    <div class="form">
      <strong>{tr("Pull request", "Pull request")}</strong>
      <div class="grid">
        <span class="faint">{tr("Branch", "Branch")}</span><span class="mono">{pr.head}</span>
        <span class="faint">{tr("Naar", "Into")}</span><input bind:value={pr.base} />
        <span class="faint">{tr("Titel", "Title")}</span><input bind:value={pr.title} />
      </div>
      <textarea bind:value={pr.body} rows="6" placeholder={tr("Beschrijving", "Description")}></textarea>
      <label class="small"><input type="checkbox" bind:checked={pr.draft} /> {tr("Als concept", "As draft")}</label>
      <span class="faint small">
        {quick?.canCreateHere
          ? tr("Via je GitHub-koppeling. Push de branch eerst.", "Through your GitHub connection. Push the branch first.")
          : tr("Geen koppeling met {host}: Nook opent de pagina met de branch ingevuld; daar maak je hem zelf. Koppel het account bij Instellingen › Koppelingen om het hier te doen.", "No connection with {host}: Nook opens the page with the branch filled in; you create it there yourself. Connect the account in Settings › Connections to do it here.", { host: quick?.hostName ?? tr("deze host", "this host") })}
      </span>
      <div class="row"><span class="spacer"></span><button class="ghost" onclick={() => (form = "")}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={!pr.title.trim() || !!busy} onclick={createPr}>{quick?.canCreateHere ? tr("Maak pull request", "Create pull request") : tr("Open op {host}", "Open on {host}", { host: quick?.hostName ?? tr("de host", "the host") })}</button></div>
    </div>
  {/if}

  <div class="split">
    <div class="tree">
      {#if !view}
        <p class="faint small">{tr("Laden…", "Loading…")}</p>
      {:else if view.snapshot?.error}
        <p class="err">{view.snapshot.error}</p>
      {:else if !view.tree.length}
        <p class="faint small">{tr("Geen wijzigingen.", "No changes.")}</p>
      {/if}
      {#each view?.tree ?? [] as row (row.path)}
        {#if visible(row)}
          {#if row.isDirectory}
            <button class="trow dir" style:padding-left="{row.depth * 12 + 4}px" onclick={() => toggleFolder(row.path)}>
              <span class="chev" class:open={!collapsed.has(row.path)}>›</span>{row.name}<span class="faint count">{row.fileCount}</span>
            </button>
          {:else}
            <button class="trow" class:on={selected === row.path} style:padding-left="{row.depth * 12 + 16}px" onclick={() => select(row.path)}>
              <span class="letter {row.kind}">{letters[row.kind ?? "modified"]}</span>
              <span class="name">{row.name}</span>
              {#if row.hasNumbers}<span class="nums"><span class="add">+{row.added}</span> <span class="rem">−{row.removed}</span></span>{/if}
            </button>
          {/if}
        {/if}
      {/each}
    </div>
    <div class="diff">
      {#if diffError}
        <p class="err">{tr("Diff niet beschikbaar: {error}", "Diff not available: {error}", { error: diffError })}</p>
      {:else if diff === null}
        <p class="faint small">{selected ? tr("Laden…", "Loading…") : tr("Kies links een bestand. Een binair bestand heeft geen tekst-diff.", "Choose a file on the left. A binary file has no text diff.")}</p>
      {:else if !diff.trim()}
        <p class="faint small">{tr("Geen verschil", "No difference")}</p>
      {:else}
        <UnifiedDiffView {diff} />
      {/if}
    </div>
  </div>
</div>

<style>
  .changes { display: flex; flex-direction: column; gap: 8px; flex: 1; min-height: 0; }
  .top { display: flex; align-items: center; gap: 8px; }
  .spacer { flex: 1; }
  .small { font-size: 12px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  .ok { color: var(--mint); font-size: 12px; margin: 0; }
  .form { display: flex; flex-direction: column; gap: 6px; padding: 10px; border: 1px solid var(--line2); border-radius: 12px; }
  .form.warn { border-color: rgba(255, 184, 77, 0.3); }
  .row { display: flex; gap: 6px; align-items: center; }
  .grid { display: grid; grid-template-columns: 70px 1fr; gap: 6px; align-items: center; font-size: 12.5px; }
  .mono { font-family: var(--mono); font-size: 12px; }
  .split { display: grid; grid-template-columns: minmax(180px, 32%) 1fr; gap: 10px; flex: 1; min-height: 0; }
  .tree { overflow-y: auto; display: flex; flex-direction: column; gap: 1px; border-right: 1px solid var(--line); padding-right: 6px; }
  .trow { display: flex; gap: 6px; align-items: center; background: none; border: none; text-align: left; padding: 3px 6px; border-radius: 6px; font-size: 12.5px; }
  .trow:hover, .trow.on { background: var(--smoke); }
  .trow.dir { color: var(--text2); }
  .chev { display: inline-block; transition: transform 0.15s; width: 10px; }
  .chev.open { transform: rotate(90deg); }
  .count { margin-left: auto; font-size: 11px; }
  .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .letter { font-family: var(--mono); font-size: 10.5px; width: 12px; color: var(--amber); }
  .letter.added, .letter.untracked { color: var(--mint); }
  .letter.deleted { color: var(--coral); }
  .nums { font-family: var(--mono); font-size: 10.5px; }
  .add { color: var(--mint); }
  .rem { color: var(--coral); }
  .diff { overflow: auto; min-height: 0; }
</style>
