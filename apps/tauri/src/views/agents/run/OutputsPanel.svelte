<script lang="ts">
  // The session's Outputs tab (`SessionOutputsPanel` on the Mac, AG-102): a strip with one tab per output (the task list,
  // each plan, each design, document, PDF, image or video the agent wrote or handed over, newest first) and the chosen one
  // below, drawn the way it is meant to be seen, with Open and Show in folder under it. A file that is written again
  // draws again.
  import { invoke } from "@tauri-apps/api/core";
  import { revealItemInDir } from "@tauri-apps/plugin-opener";
  import { tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import { checklistProgress } from "../../../lib/task-steps";
  import { readFile } from "../../../lib/workspace/file-editor.svelte";
  import { fileName } from "../../../lib/workspace/file-links";
  import type { OutputKind, SessionOutput } from "../../../lib/workspace/session-outputs";
  import EmptyState from "../EmptyState.svelte";
  import Markdown from "../../../components/Markdown.svelte";
  import TaskChecklist from "../../../components/TaskChecklist.svelte";
  import PdfPointViewer from "./PdfPointViewer.svelte";
  import Spinner from "../../../components/ui/Spinner.svelte";
  import Ico from "../../../components/ui/Ico.svelte";

  let { outputs, selected, onselect, folder = null, live = false, onrun, runId = null }: {
    outputs: SessionOutput[];
    selected: string | null;
    onselect: (id: string) => void;
    folder?: string | null;
    live?: boolean;
    onrun?: (command: string, title: string | null) => void;
    runId?: string | null;
  } = $props();

  const current = $derived(outputs.find((o) => o.id === selected) ?? outputs[0] ?? null);
  const ICONS: Record<OutputKind, string> = { tasks: "list-checks", plan: "clipboard-list", design: "palette", document: "file-text", pdf: "file", image: "image", video: "file-video" };
  const title = (o: SessionOutput) => (o.kind === "tasks" ? tr("Taken", "Tasks") : o.kind === "plan" ? o.title || tr("Plan", "Plan") : o.title);
  const kindLabel = (o: SessionOutput) =>
    ({ tasks: tr("Taken", "Tasks"), plan: tr("Plan", "Plan"), design: tr("Ontwerp", "Design"), document: tr("Document", "Document"), pdf: "PDF", image: tr("Afbeelding", "Image"), video: tr("Video", "Video") })[o.kind];

  // What the chosen file is: its text (a design or a document) or an address the page can show (a picture, PDF, video).
  let text = $state<string | null>(null);
  let url = $state<string | null>(null);
  let missing = $state<string | null>(null);
  let copied = $state(false);

  $effect(() => {
    const o = current;
    text = null;
    url = null;
    missing = null;
    if (!o?.path || o.kind === "pdf") return;
    const path = o.path;
    void o.date;
    let stale = false;
    let made: string | null = null;
    if (o.kind === "design" || o.kind === "document") {
      readFile(path).then((v) => { if (!stale) { if (v.kind === "text" && v.file) text = v.file.text.slice(0, 400_000); else missing = tr("Dit bestand is er niet meer.", "This file is no longer there."); } })
        .catch((e) => { if (!stale) missing = String(e); });
    } else {
      invoke<{ mediaType: string; base64: string | null }>("file_preview", { path }).then((f) => {
        if (stale) return;
        if (!f.base64) { missing = tr("Dit bestand is te groot om hier te tonen; open het in zijn app.", "This file is too large to show here; open it in its app."); return; }
        const bytes = Uint8Array.from(atob(f.base64), (c) => c.charCodeAt(0));
        made = URL.createObjectURL(new Blob([bytes], { type: f.mediaType }));
        url = made;
      }).catch((e) => { if (!stale) missing = String(e); });
    }
    return () => { stale = true; if (made) URL.revokeObjectURL(made); };
  });

  // A design runs its own scripts but cannot reach the network, Nook or the window: no same origin, no forms, popups or
  // navigation, and a content policy on top.
  const page = $derived(text !== null && current?.kind === "design"
    ? `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; media-src data: blob:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">${text}` : null);

  const open = () => current?.path && invoke("file_open_in_app", { path: current.path }).catch((e) => toast.error(tr("Kon het bestand niet openen", "Could not open the file"), e));
  const reveal = () => current?.path && revealItemInDir(current.path).catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e));
  function copy() {
    if (!current) return;
    const out = current.kind === "plan" ? (current.text ?? "") : (current.steps ?? []).map((s) => (s.status === "done" ? "- [x] " : "- [ ] ") + s.text).join("\n");
    navigator.clipboard?.writeText(out).then(() => { copied = true; setTimeout(() => (copied = false), 1200); });
  }
</script>

{#if !current}
  <EmptyState symbol="clipboard-list" title={tr("Nog niets te zien", "Nothing to show yet")}
    message={tr("De takenlijst van de agent, de plannen die hij voorstelt en de ontwerpen, documenten en afbeeldingen die hij schrijft verschijnen hier.", "The agent's task list, the plans it proposes and the designs, documents and images it writes appear here.")} />
{:else}
  <div class="outputs">
    <div class="strip" role="tablist">
      {#each outputs as o (o.id)}
        <button role="tab" aria-selected={o.id === current.id} class="tab" class:on={o.id === current.id} title={title(o)} onclick={() => onselect(o.id)}>
          <Ico name={ICONS[o.kind]} size={12} stroke={2} /><span class="tname">{title(o)}</span>
        </button>
      {/each}
    </div>
    <div class="content" data-kind={current.kind}>
      {#if current.kind === "tasks"}
        <div class="pad"><TaskChecklist steps={current.steps ?? []} {live} /></div>
      {:else if current.kind === "plan"}
        <div class="pad"><Markdown text={current.text ?? ""} baseFolder={folder} {onrun} /></div>
      {:else if current.kind === "pdf" && current.path}
        <PdfPointViewer {runId} path={current.path} version={current.date} />
      {:else if missing}
        <p class="note">{missing}</p>
      {:else if current.kind === "design"}
        {#if page}{#key current.date}<iframe class="page" sandbox="allow-scripts" srcdoc={page} title={title(current)}></iframe>{/key}{:else}<div class="center"><Spinner /></div>{/if}
      {:else if current.kind === "document"}
        <div class="pad">{#if text !== null}<Markdown {text} baseFolder={folder ?? current.path?.replace(/[\\/][^\\/]*$/, "") ?? null} />{:else}<div class="center"><Spinner /></div>{/if}</div>
      {:else if !url}
        <div class="center"><Spinner /></div>
      {:else if current.kind === "image"}
        <img src={url} alt={title(current)} />
      {:else}
        <!-- svelte-ignore a11y_media_has_caption -->
        <video src={url} controls></video>
      {/if}
    </div>
    <div class="actions">
      {#if current.path}
        <span class="path" title={current.path}>{current.path}</span>
        <button class="ghost small" onclick={open}>{tr("Openen", "Open")}</button>
        <button class="ghost small" onclick={reveal}>{tr("Toon in map", "Show in folder")}</button>
      {:else}
        <span class="path">{kindLabel(current)}{#if current.kind === "tasks"} · {tr("{done} van {total} klaar", "{done} of {total} done", checklistProgress(current.steps ?? []))}{/if}</span>
        <button class="ghost small" onclick={copy}>{copied ? tr("Gekopieerd", "Copied") : current.kind === "plan" ? tr("Kopieer plan", "Copy plan") : tr("Kopieer", "Copy")}</button>
      {/if}
    </div>
  </div>
{/if}

<style>
  .outputs { display: flex; flex-direction: column; flex: 1; min-height: 0; }
  .strip { display: flex; flex: none; height: 40px; overflow-x: auto; padding: 0 var(--space-6); border-bottom: 1px solid var(--hairline); }
  .tab { display: inline-flex; align-items: center; gap: var(--space-6); flex: none; margin: 0; padding: 0 var(--space-12); border: 0; border-bottom: 2px solid transparent; border-radius: 0; background: transparent; color: var(--text2); font: var(--text-detail); }
  .tab:hover { color: var(--paper); }
  .tab.on { color: var(--paper); border-bottom-color: var(--iris); font: var(--text-label); }
  .tname { max-width: 160px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .content { flex: 1; min-height: 0; overflow: auto; display: flex; flex-direction: column; background: var(--canvas); }
  .content[data-kind="image"], .content[data-kind="video"] { align-items: center; justify-content: center; padding: var(--space-8); }
  .pad { padding: var(--space-16) var(--space-8); }
  .center { display: grid; place-items: center; flex: 1; padding: var(--space-16); }
  .note { margin: 0; padding: var(--space-16); font: var(--text-detail); color: var(--text3); }
  .page { flex: 1; width: 100%; border: 0; background: var(--paper); }
  img, video { max-width: 100%; max-height: 100%; object-fit: contain; }
  .actions { display: flex; align-items: center; gap: var(--space-8); flex: none; height: 34px; padding: 0 var(--space-12); border-top: 1px solid var(--hairline); }
  .path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl; text-align: left; font: var(--text-caption); font-family: var(--mono); color: var(--text3); }
</style>
