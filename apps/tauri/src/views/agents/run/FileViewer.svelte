<script lang="ts">
  // A file read in Nook, the way an editor shows it (`FileViewer` on the Mac, AG-101): line numbers in a gutter, syntax
  // colors, the link's line in view and marked. Markdown reads as a document and a Mermaid file as its picture, one
  // click from the code. A text file can be edited in place and saved with Ctrl+S (a `.env`, a config) without opening
  // another editor; a file that changed on disk since you opened it is only overwritten after you confirm. A remark on
  // a line goes to the session's composer. Nothing in it runs the file.
  import { untrack } from "svelte";
  import { revealItemInDir } from "@tauri-apps/plugin-opener";
  import { tr } from "../../../lib/i18n.svelte";
  import { ask } from "../../../lib/confirm.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import { previewable, previewFile } from "../../../lib/file-preview.svelte";
  import { workspaceApi } from "../../../lib/workspace/api";
  import { composerInbox } from "../../../lib/workspace/composer-inbox.svelte";
  import { fileLine } from "../../../lib/workspace/session-prompts";
  import { editorFor, readFile, type FileView } from "../../../lib/workspace/file-editor.svelte";
  import { clampedLine, fileKind, lineHtml, opensOnPreview, splitLines } from "../../../lib/workspace/file-view";
  import { fileName, lineLabel } from "../../../lib/workspace/file-links";
  import { renderMermaid } from "../../../lib/rich";
  import { historyOf, recordVersion, unifiedDiff } from "../../../lib/workspace/artifact-history";
  import { isPdfPath } from "../../../lib/workspace/pdf-point";
  import UnifiedDiffView from "../UnifiedDiffView.svelte";
  import PdfPointViewer from "./PdfPointViewer.svelte";
  import { invoke } from "@tauri-apps/api/core";
  import Markdown from "../../../components/Markdown.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import IconButton from "../../../components/ui/IconButton.svelte";
  import Spinner from "../../../components/ui/Spinner.svelte";

  let { runId, path, line, endLine, opened = 0, folder = null }: {
    runId: string; path: string; line?: number; endLine?: number;
    /** Changes on every open: scroll to the link's line again. */
    opened?: number;
    folder?: string | null;
  } = $props();

  const editor = $derived(editorFor(path));
  const kind = $derived(fileKind(path));
  let view = $state<FileView | null>(null);
  let failed = $state<string | null>(null);
  let updating = $state(false);
  // What you chose with the Preview / Code toggle; null leaves it to the kind of file.
  let override = $state<boolean | null>(null);
  const previewing = $derived(override ?? opensOnPreview(kind, line));
  // The versions of the file while it is open (`ArtifactHistory`): `viewing` is an older one in view, null for the file as it
  // is; `comparing` shows what it changed from the version before.
  let versionTick = $state(0);
  let viewing = $state<number | null>(null);
  let comparing = $state(false);
  let versionList = $state(false);
  const history = $derived((void versionTick, historyOf(path)));
  const version = $derived(viewing === null ? null : (history.version(viewing) ?? null));
  const current = $derived(view?.kind === "text" ? (view.file?.text ?? "") : "");
  const text = $derived(version ? version.text : current);
  const versionDiff = $derived(version && comparing ? unifiedDiff(history.previous(version.number)?.text ?? "", version.text, fileName(path)) : null);
  const lines = $derived(splitLines(text));
  const html = $derived(editor.editing ? [] : lineHtml(lines, path));
  const marked = $derived(clampedLine(line, lines.length));
  const markedEnd = $derived(marked !== null && endLine && endLine > marked ? Math.min(endLine, lines.length) : marked);
  const digits = $derived(String(lines.length).length);
  let diagram = $state<string | null>(null);
  let commentLine = $state<number | null>(null);
  let note = $state("");
  let scroller = $state<HTMLElement>();

  async function load(quiet: boolean) {
    if (quiet) updating = true;
    try {
      const next = await readFile(path);
      // Only a change in the file redraws: a read that finds the same file leaves the view (and its scroll) alone.
      if (!view || view.kind !== next.kind || view.size !== next.size || view.file?.text !== next.file?.text || view.file?.modified !== next.file?.modified) view = next;
      if (next.kind === "text" && next.file && recordVersion(path, next.file.text)) versionTick += 1;
      failed = null;
    } catch (e) {
      failed = String(e);
    } finally {
      updating = false;
    }
  }

  // Reads the file when it opens, and again every few seconds while you only read it: an agent that writes it shows.
  $effect(() => {
    void path;
    untrack(() => { view = null; override = null; commentLine = null; viewing = null; comparing = false; versionList = false; });
    void load(false);
    const timer = setInterval(() => { if (!editorFor(path).editing) void load(true); }, 3000);
    return () => clearInterval(timer);
  });

  $effect(() => {
    void opened;
    if (!scroller || marked === null) return;
    const el = scroller.querySelector(`[data-line="${marked}"]`);
    el?.scrollIntoView({ block: "center" });
  });

  $effect(() => {
    diagram = null;
    if (kind !== "diagram" || !previewing || !text) return;
    let stale = false;
    void renderMermaid(text).then((svg) => { if (!stale) diagram = svg; });
    return () => { stale = true; };
  });

  // A page (HTML or SVG) draws in a frame with nothing allowed: no scripts, no network, no links, no windows.
  const page = $derived(kind === "page" && previewing && text
    ? `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">${text}` : null);

  async function edit() {
    if (!(await editor.begin())) toast.error(tr("Dit bestand kan niet als tekst bewerkt worden", "This file can't be edited as text"), fileName(path));
    else override = false;
  }

  async function save() {
    if (!editor.editing) return;
    let result = await editor.save().catch((e) => ({ result: "failed" as const, reason: String(e) }));
    if (result.result === "changedOnDisk") {
      const yes = await ask({
        question: tr("Bestand is intussen gewijzigd", "The file changed"),
        detail: tr("{file} is op schijf gewijzigd sinds je het opende. Overschrijven met jouw versie?", "{file} changed on disk since you opened it. Overwrite it with your version?", { file: fileName(path) }),
        confirmTitle: tr("Overschrijven", "Overwrite"),
      });
      if (!yes) return;
      result = await editor.save(true).catch((e) => ({ result: "failed" as const, reason: String(e) }));
    }
    if (result.result === "saved") {
      toast.success(tr("Opgeslagen", "Saved"), fileName(path));
      await load(false);
    } else if (result.result === "failed") toast.error(tr("Opslaan mislukt", "Couldn't save"), result.reason);
  }

  async function stopEditing() {
    if (editor.unsaved) {
      const yes = await ask({
        question: tr("Wijzigingen weggooien?", "Discard changes?"),
        detail: tr("Je wijzigingen in {file} zijn niet opgeslagen.", "Your changes to {file} are not saved.", { file: fileName(path) }),
        confirmTitle: tr("Weggooien", "Discard"),
      });
      if (!yes) return;
    }
    editor.end();
  }

  function keydown(e: KeyboardEvent) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s" && editor.editing) { e.preventDefault(); void save(); }
  }

  function send() {
    if (commentLine === null || !note.trim()) return;
    composerInbox.add(fileLine(path, commentLine, lines[commentLine - 1] ?? "", note), runId);
    commentLine = null;
    note = "";
  }

  /// Writes an older version over the file, the way the file was written (its encoding and line breaks).
  async function restore() {
    if (!version || !view?.file) return;
    const result = await invoke<{ result: string; reason?: string }>("workspace_file_save", { path, text: version.text, file: view.file, overwrite: true }).catch((e) => ({ result: "failed", reason: String(e) }));
    if (result.result !== "saved") { toast.error(tr("Opslaan mislukt", "Couldn't save"), result.reason); return; }
    viewing = null;
    comparing = false;
    await load(false);
    toast.success(tr("Versie hersteld", "Version restored"), fileName(path));
  }

  const clock = (ms: number) => new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const openInEditor = () => workspaceApi.openIn(path).catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e));
  const copyPath = () => navigator.clipboard?.writeText(path).then(() => toast.success(tr("Gekopieerd", "Copied"), path));
  const reveal = () => revealItemInDir(path).catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e));
  const place = $derived(lineLabel({ path, line, endLine }));
</script>

<svelte:window onkeydown={keydown} />

<div class="viewer">
  <div class="bar">
    <Ico name="file-text" size={14} stroke={1.9} />
    <span class="name truncate" title={path}>{fileName(path)}</span>
    {#if place}<span class="place">{place}</span>{/if}
    {#if updating}<span class="place">{tr("Bijwerken…", "Updating…")}</span>{/if}
    {#if editor.unsaved}<span class="dot" title={tr("Niet opgeslagen", "Not saved")}></span>{/if}
    <span class="spacer"></span>
    {#if view?.kind === "text"}
      {#if kind !== "code" && !editor.editing}
        <IconButton title={previewing ? tr("Code", "Code") : tr("Voorbeeld", "Preview")} onclick={() => (override = !previewing)}><Ico name={previewing ? "code" : "eye"} size={14} /></IconButton>
      {/if}
      {#if !editor.editing && history.versions.length > 1}
        <IconButton title={tr("Versies", "Versions")} onclick={() => (versionList = !versionList)}><Ico name="history" size={14} /></IconButton>
      {/if}
      {#if editor.editing}
        <IconButton title={tr("Opslaan (Ctrl+S)", "Save (Ctrl+S)")} onclick={save} disabled={!editor.unsaved}><Ico name="check" size={14} stroke={2.2} /></IconButton>
        <IconButton title={tr("Klaar", "Done")} onclick={stopEditing}><Ico name="x" size={14} /></IconButton>
      {:else if viewing === null && kind !== "page"}
        <IconButton title={tr("Bewerken", "Edit")} onclick={edit}><Ico name="pencil" size={14} /></IconButton>
      {/if}
    {/if}
    <IconButton title={tr("Open in editor", "Open in editor")} onclick={openInEditor}><Ico name="external-link" size={14} /></IconButton>
    <IconButton title={tr("Toon in map", "Show in folder")} onclick={reveal}><Ico name="folder" size={14} /></IconButton>
    <IconButton title={tr("Pad kopiëren", "Copy path")} onclick={copyPath}><Ico name="copy" size={14} /></IconButton>
  </div>

  {#if versionList && !editor.editing}
    <div class="versions">
      <button class="version" class:on={viewing === null} onclick={() => { viewing = null; comparing = false; versionList = false; }}>{tr("Nieuwste", "Latest")}</button>
      {#each [...history.versions].reverse() as v (v.number)}
        <button class="version" class:on={viewing === v.number} onclick={() => { viewing = v.number; versionList = false; }}>
          {tr("Versie {n} van {total}", "Version {n} of {total}", { n: v.number, total: history.latest?.number ?? v.number })}<span class="faint">{clock(v.date)}</span>
        </button>
      {/each}
    </div>
  {/if}
  {#if version}
    <!-- `ArtifactVersionBar`: an older version in view; compare it with the one before, restore it, or go back. -->
    <div class="bar version-bar">
      <Ico name="history" size={14} />
      <span class="vname truncate">{tr("Versie {n} van {total}", "Version {n} of {total}", { n: version.number, total: history.latest?.number ?? version.number })}</span>
      <span class="place">{clock(version.date)}</span>
      <span class="spacer"></span>
      <IconButton title={tr("Vergelijk met de vorige versie", "Compare with the previous version")} onclick={() => (comparing = !comparing)}><Ico name="diff" size={14} stroke={comparing ? 2.6 : 2} /></IconButton>
      <IconButton title={tr("Deze versie herstellen", "Restore this version")} onclick={restore}><Ico name="undo-2" size={14} /></IconButton>
      <IconButton title={tr("Terug naar de nieuwste", "Back to the latest")} onclick={() => { viewing = null; comparing = false; }}><Ico name="arrow-right-to-line" size={14} /></IconButton>
    </div>
  {/if}

  {#if !failed && view?.kind === "preview" && isPdfPath(path)}
    <PdfPointViewer {runId} {path} version={`${opened}:${view.size}`} />
  {:else}
    <div class="body" bind:this={scroller}>
      {#if failed}
        <p class="note">{failed}</p>
      {:else if !view}
        <div class="center"><Spinner /></div>
      {:else if view.kind === "missing"}
        <p class="note">{tr("Dit bestand bestaat niet (meer).", "This file no longer exists.")}</p>
      {:else if view.kind === "folder"}
        <p class="note">{tr("Dit is een map.", "This is a folder.")}</p>
        <div class="center"><button class="ghost" onclick={reveal}>{tr("Toon in map", "Show in folder")}</button></div>
      {:else if view.kind === "preview"}
        <p class="note">{tr("Nook kan dit bestand niet als tekst tonen.", "Nook can't show this file as text.")}</p>
        <div class="center">
          {#if previewable(path)}<button class="primary" onclick={() => previewFile(path)}>{tr("Voorbeeld", "Preview")}</button>{/if}
          <button class="ghost" onclick={openInEditor}>{tr("Open in app", "Open in app")}</button>
        </div>
      {:else if versionDiff !== null}
        {#if versionDiff}<UnifiedDiffView diff={versionDiff} />{:else}<p class="note">{tr("Geen wijzigingen ten opzichte van de vorige versie", "No changes from the previous version")}</p>{/if}
      {:else if editor.editing}
        <textarea class="edit" bind:value={editor.draft} spellcheck="false" wrap="off" aria-label={fileName(path)}></textarea>
      {:else if previewing && kind === "markdown"}
        <div class="doc"><Markdown {text} baseFolder={folder ?? path.replace(/[\\/][^\\/]*$/, "")} /></div>
      {:else if previewing && kind === "diagram"}
        <div class="doc">{#if diagram}{@html diagram}{:else}<p class="note">{tr("Dit diagram kon niet worden getekend.", "This diagram could not be drawn.")}</p>{/if}</div>
      {:else if page}
        <iframe class="page" sandbox="" srcdoc={page} title={fileName(path)}></iframe>
      {:else}
        <div class="code" style:--digits="{digits}ch">
          {#each html as row, i (i)}
            {@const n = i + 1}
            <div class="row" class:marked={marked !== null && markedEnd !== null && n >= marked && n <= markedEnd} data-line={n}>
              <button class="num" title={tr("Opmerking bij deze regel", "Comment on this line")} aria-label={tr("Opmerking bij deze regel", "Comment on this line")} onclick={() => { commentLine = n; note = ""; }}>{n}</button>
              <span class="text">{@html row || " "}</span>
            </div>
            {#if commentLine === n}
              <div class="comment">
                <span class="faint">{tr("regel {line}", "line {line}", { line: n })}</span>
                <!-- svelte-ignore a11y_autofocus -->
                <input bind:value={note} autofocus placeholder={tr("Wat moet hier anders?", "What should change here?")}
                  onkeydown={(e) => { if (e.key === "Enter") send(); if (e.key === "Escape") commentLine = null; }} />
                <IconButton title={tr("Aan de composer toevoegen", "Add to the composer")} onclick={send} disabled={!note.trim()}><Ico name="arrow-up" size={14} /></IconButton>
                <IconButton title={tr("Annuleer", "Cancel")} onclick={() => (commentLine = null)}><Ico name="x" size={14} /></IconButton>
              </div>
            {/if}
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .viewer { display: flex; flex-direction: column; flex: 1; min-height: 0; }
  .bar { display: flex; align-items: center; gap: var(--space-6); min-height: 40px; padding: 0 var(--space-8) 0 var(--space-12); border-bottom: 1px solid var(--hairline); color: var(--text2); }
  .name { font: var(--text-emphasis); color: var(--paper); min-width: 0; }
  .truncate { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .place { font: var(--text-detail); color: var(--text3); flex: none; }
  .dot { width: 7px; height: 7px; border-radius: var(--radius-pill); background: var(--amber); flex: none; }
  .spacer { flex: 1; }
  .version-bar { color: var(--amber); }
  .vname { font: var(--text-detail); color: var(--text-strong); }
  .versions { display: flex; flex-direction: column; border-bottom: 1px solid var(--hairline); max-height: 180px; overflow: auto; }
  .version { display: flex; justify-content: space-between; gap: var(--space-8); margin: 0; padding: var(--space-6) var(--space-12); border: 0; border-radius: 0; background: transparent; color: var(--text2); font: var(--text-detail); text-align: left; }
  .version:hover { background: var(--row-hover); }
  .version.on { color: var(--paper); }
  .body { flex: 1; min-height: 0; overflow: auto; background: var(--canvas); }
  .center { display: flex; justify-content: center; gap: var(--space-8); padding: var(--space-16); }
  .note { margin: 0; padding: var(--space-24) var(--space-16) var(--space-8); font: var(--text-body); color: var(--text2); text-align: center; }
  .doc { padding: var(--space-16); }
  .page { width: 100%; height: 100%; border: 0; background: var(--paper); }
  .edit { display: block; width: 100%; height: 100%; margin: 0; padding: var(--space-12); border: 0; border-radius: 0; resize: none; background: var(--canvas); color: var(--paper); font: var(--text-code); tab-size: 4; white-space: pre; }
  .code { padding: var(--space-8) 0; font: var(--text-code); min-width: max-content; }
  .row { display: flex; }
  .row.marked { background: color-mix(in srgb, var(--amber) 14%, transparent); }
  .num { flex: none; width: calc(var(--digits) + var(--space-16)); margin: 0; padding: 0 var(--space-8) 0 0; border: 0; border-radius: 0; background: transparent; color: var(--text3); font: inherit; text-align: right; user-select: none; }
  .num:hover { color: var(--blue); }
  .text { white-space: pre; padding-right: var(--space-16); color: var(--paper); }
  .text :global(.tok-keyword) { color: var(--syntax-keyword); }
  .text :global(.tok-string) { color: var(--syntax-string); }
  .text :global(.tok-comment) { color: var(--syntax-comment); }
  .text :global(.tok-number) { color: var(--syntax-number); }
  .text :global(.tok-type) { color: var(--syntax-type); }
  .text :global(.tok-property) { color: var(--syntax-property); }
  .text :global(.tok-tag) { color: var(--syntax-tag); }
  .text :global(.tok-attribute) { color: var(--syntax-attribute); }
  .comment { position: sticky; left: 0; display: flex; align-items: center; gap: var(--space-6); padding: var(--space-4) var(--space-12); background: var(--surface); border-block: 1px solid var(--line2); font: var(--text-detail); }
  .comment input { flex: 1; min-width: 0; font: var(--text-detail); }
  .faint { color: var(--text3); }
</style>
