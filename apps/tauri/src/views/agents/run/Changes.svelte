<script lang="ts">
  // De wijzigingen van een sessie (`ChangesViews` en `GitQuickButton` op de Mac): de boom met gewijzigde bestanden, de
  // diff van het gekozen bestand, en de ene git-knop (commit, push, pull request of pull, wat er nu past). Alles
  // gebeurt pas na jouw klik; pushen naar de standaardbranch vraagt eerst of je dat echt wilt.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { agents } from "../../../lib/agents.svelte";
  import { isActive, workspaceApi, type FileChange, type GitView, type QuickView, type TreeRow, type WorkspaceRun } from "../../../lib/workspace/api";
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

  /// De knop: committen vraagt eerst het bericht, pushen naar de standaardbranch een bevestiging, een PR het formulier.
  function quickClick() {
    if (!quick?.action) return;
    done = null;
    if (quick.action.startsWith("commit")) {
      subject = subject || run.title;
      form = "commit";
    } else if (quick.state.isDefaultBranch && quick.action === "push") {
      form = "confirmDefault";
    } else if (quick.action === "pull") {
      step("Pullen…", () => workspaceApi.pull(run.id)).then(() => load(false));
    } else {
      continueAfterCommit();
    }
  }

  async function commit() {
    if (!subject.trim()) return;
    const ok = await step("Committen…", async () => {
      const sha = await workspaceApi.commitAll(run.id, subject, body);
      done = `Gecommit als ${sha}`;
    });
    form = "";
    if (!ok) return;
    subject = "";
    body = "";
    if (quick?.action === "commitPush" || quick?.action === "commitPushPr") {
      if (quick.state.isDefaultBranch) form = "confirmDefault";
      else await continueAfterCommit();
    }
    load(false);
  }

  async function push(): Promise<boolean> {
    return step("Pushen…", async () => {
      const branch = await workspaceApi.push(run.id);
      done = `Gepusht: ${branch}`;
    });
  }

  async function continueAfterCommit() {
    form = "";
    const action = quick?.action;
    const pushes = action && action !== "commit" && action !== "pull" && action !== "createPr";
    if (pushes && !(await push())) return;
    if (action === "commitPushPr" || action === "pushPr" || action === "createPr") await openPrForm();
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
    await step("Pull request openen…", async () => {
      const r = await workspaceApi.createPullRequest(run.id, pr);
      form = "";
      if (r.created) {
        done = "Pull request gemaakt";
        agents.confirm("Pull request gemaakt");
      }
      await openUrl(r.url);
    });
    load(false);
  }
</script>

<div class="changes">
  <div class="top">
    <strong>Wijzigingen</strong>
    <span class="faint small">{run.branch ? `Op ${run.branch}` : ""}{view?.snapshot?.status ? ` · ${files.length} bestanden` : ""}</span>
    <span class="spacer"></span>
    {#if quick?.pullRequest}<button class="ghost" onclick={() => openUrl(quick!.pullRequest!)}>Bekijk PR</button>{/if}
    <button class="primary" disabled={!quick?.action || active || !!busy}
      title={quick?.reason ?? "Wat de knop doet hangt af van de branch: committen, pushen, een pull request maken of pullen."} onclick={quickClick}>
      {busy ?? quick?.label ?? "Git"}
    </button>
    <button class="ghost" title="Opnieuw lezen" onclick={() => load(true)}>↻</button>
    <button class="ghost" onclick={onclose}>Sluit</button>
  </div>
  {#if quick && !quick.action && quick.reason}<p class="faint small">{quick.reason}</p>{/if}
  {#if active}<p class="faint small">De agent werkt nog; committen en pushen kan als hij klaar is.</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}
  {#if done}<p class="ok">{done}</p>{/if}

  {#if form === "commit"}
    <div class="form">
      <div class="faint small">Op {quick?.state.branch ?? "?"} in {run.workingDirectory}. Er wordt alleen gecommit; pushen doet de knop daarna.</div>
      <input bind:value={subject} placeholder="Bericht" />
      <textarea bind:value={body} rows="3" placeholder="Toelichting (optioneel)"></textarea>
      <div class="row"><button class="ghost" onclick={() => (subject = run.title)}>Gebruik de naam van de sessie</button><span class="spacer"></span>
        <button class="ghost" onclick={() => (form = "")}>Annuleer</button>
        <button class="primary" disabled={!subject.trim() || !!busy} onclick={commit}>Commit {files.length} bestanden</button></div>
    </div>
  {:else if form === "confirmDefault"}
    <div class="form warn">
      <strong>Naar {quick?.state.branch} pushen?</strong>
      <span class="faint small">Dit is de standaardbranch. De wijzigingen gaan meteen naar {quick?.state.branch} op de remote.</span>
      <div class="row"><span class="spacer"></span><button class="ghost" onclick={() => (form = "")}>Annuleer</button>
        <button class="primary" onclick={async () => { form = ""; await push(); load(false); }}>Toch pushen</button></div>
    </div>
  {:else if form === "pr"}
    <div class="form">
      <strong>Pull request</strong>
      <div class="grid">
        <span class="faint">Branch</span><span class="mono">{pr.head}</span>
        <span class="faint">Naar</span><input bind:value={pr.base} />
        <span class="faint">Titel</span><input bind:value={pr.title} />
      </div>
      <textarea bind:value={pr.body} rows="6" placeholder="Beschrijving"></textarea>
      <label class="small"><input type="checkbox" bind:checked={pr.draft} /> Als concept</label>
      <span class="faint small">
        {quick?.canCreateHere
          ? "Via je GitHub-koppeling. Push de branch eerst."
          : `Geen koppeling met ${quick?.hostName ?? "deze host"}: Nook opent de pagina met de branch ingevuld; daar maak je hem zelf. Koppel het account bij Instellingen › Koppelingen om het hier te doen.`}
      </span>
      <div class="row"><span class="spacer"></span><button class="ghost" onclick={() => (form = "")}>Annuleer</button>
        <button class="primary" disabled={!pr.title.trim() || !!busy} onclick={createPr}>{quick?.canCreateHere ? "Maak pull request" : `Open op ${quick?.hostName ?? "de host"}`}</button></div>
    </div>
  {/if}

  <div class="split">
    <div class="tree">
      {#if !view}
        <p class="faint small">Laden…</p>
      {:else if view.snapshot?.error}
        <p class="err">{view.snapshot.error}</p>
      {:else if !view.tree.length}
        <p class="faint small">Geen wijzigingen.</p>
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
        <p class="err">Diff niet beschikbaar: {diffError}</p>
      {:else if diff === null}
        <p class="faint small">{selected ? "Laden…" : "Kies links een bestand. Een binair bestand heeft geen tekst-diff."}</p>
      {:else if !diff.trim()}
        <p class="faint small">Geen verschil</p>
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
