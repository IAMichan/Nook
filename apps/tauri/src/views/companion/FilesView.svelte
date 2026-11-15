<script lang="ts">
  // A session's folder, as the iPhone's Files (`WorkspaceViews`): folders and files to open, a text file to read, and
  // any other file (a picture, a PDF, a film) fetched in pieces to preview (`fileData`, up to 8 MB). The Mac decides
  // what goes: only inside the session's folder, never .git, .env or key files.
  import { onDestroy } from "svelte";
  import { companion, fileKind, has, FileAssembly, Feature, type ClientView, type FolderDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import NavBar from "./ui/NavBar.svelte";
  import Ico from "./ui/Ico.svelte";
  import EmptyState from "./ui/EmptyState.svelte";

  let { view, session, onback, took }: { view: ClientView; session: string; onback: () => void; took: (v: ClientView) => void } = $props();
  let stack = $state<string[]>([""]);
  let folder = $state<FolderDigest | null>(null);
  let failed = $state(false);
  let preview = $state<{ url: string; kind: string; name: string } | null>(null);
  let loadingPreview = $state(false);
  const path = $derived(stack[stack.length - 1]);
  const name = $derived(path ? path.split("/").pop()! : tr("Bestanden", "Files"));

  async function load(p: string) {
    folder = null;
    failed = false;
    clearPreview();
    const r = await companion.call({ op: "files", session, item: p });
    if (!r.response?.folder) { failed = true; took({ ...r.view, notice: null }); companion.clearNotice(); return; }
    folder = r.response.folder;
    if (folder.binary && has(view, Feature.filePreview)) fetchPreview(p);
  }
  $effect(() => { void load(path); });

  async function fetchPreview(p: string) {
    loadingPreview = true;
    const parts = new FileAssembly();
    while (!parts.done) {
      const r = await companion.call({ op: "fileData", session, item: p, text: String(parts.next) });
      const chunk = r.response?.fileChunk;
      if (!chunk || !parts.add(chunk) || stack[stack.length - 1] !== p) { loadingPreview = false; return; }
      if (chunk.total === 0) break;
    }
    const kind = fileKind(p);
    const type = kind === "image" ? (p.toLowerCase().endsWith(".png") ? "image/png" : p.toLowerCase().endsWith(".svg") ? "image/svg+xml" : "image/jpeg") : kind === "pdf" ? "application/pdf" : kind === "video" ? "video/mp4" : kind === "audio" ? "audio/mpeg" : "application/octet-stream";
    preview = { url: URL.createObjectURL(parts.blob(type)), kind, name: p.split("/").pop() ?? p };
    loadingPreview = false;
  }
  function clearPreview() {
    if (preview) URL.revokeObjectURL(preview.url);
    preview = null;
  }
  onDestroy(clearPreview);

  function back() {
    if (stack.length > 1) stack = stack.slice(0, -1);
    else onback();
  }
  const icon = (e: { name: string; isFolder: boolean }) => (e.isFolder ? "folder" : ({ image: "file-image", video: "file-video", audio: "file-audio", pdf: "file-text", text: "file-text" } as Record<string, string>)[fileKind(e.name)] ?? "file");
</script>

<div class="files">
  <NavBar onback={back}>{#snippet center()}<strong class="t">{name}</strong>{/snippet}</NavBar>
  <div class="scroll">
    {#if failed}
      <EmptyState icon="circle-alert" title={tr("Niet beschikbaar", "Not available")} text={tr("De Mac deelt dit niet.", "The Mac does not share this.")} />
    {:else if !folder}
      <div class="spinner"></div>
    {:else if folder.entries}
      {#each folder.entries as e (e.name)}
        <button class="entry row-press" onclick={() => (stack = [...stack, path ? `${path}/${e.name}` : e.name])}>
          <span class="icon"><Ico name={icon(e)} size={16} /></span><span class="name">{e.name}</span><Ico name="chevron-right" size={12} stroke={2.6} />
        </button>
      {/each}
      {#if folder.truncated}<p class="note">{tr("Alleen de eerste items van deze map worden getoond.", "Only the first entries of this folder are shown.")}</p>{/if}
    {:else if folder.text !== undefined && !folder.binary}
      <pre class="text">{folder.text}</pre>
      {#if folder.truncated}<p class="note">{tr("Alleen het begin van dit bestand wordt getoond.", "Only the start of this file is shown.")}</p>{/if}
    {:else if preview}
      {#if preview.kind === "image"}<img src={preview.url} alt={preview.name} />
      {:else if preview.kind === "video"}<!-- svelte-ignore a11y_media_has_caption --><video src={preview.url} controls></video>
      {:else if preview.kind === "audio"}<audio src={preview.url} controls></audio>
      {:else if preview.kind === "pdf"}<iframe src={preview.url} title={preview.name}></iframe>
      {:else}<EmptyState icon="file" title={tr("Geen tekst", "No text")} text={tr("Dit bestand kan niet op de telefoon worden getoond.", "This file cannot be shown on the phone.")} />{/if}
    {:else if loadingPreview}
      <div class="spinner"></div>
    {:else}
      <EmptyState icon="file" title={tr("Geen tekst", "No text")} text={tr("Dit bestand kan niet op de telefoon worden getoond.", "This file cannot be shown on the phone.")} />
    {/if}
  </div>
</div>

<style>
  .files { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .t { font: var(--pt-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 240px; }
  .scroll { flex: 1; overflow: auto; padding: 8px 16px 24px; }
  .entry { width: 100%; display: flex; align-items: center; gap: 10px; padding: 10px 8px; text-align: left; color: var(--text3) !important; }
  .icon { color: var(--text2); display: inline-flex; }
  .name { flex: 1; min-width: 0; font: var(--pt-label); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .text { margin: 0; font: var(--pt-code); font-size: 12px; color: var(--paper); white-space: pre; user-select: text; }
  .note { margin: 8px 0 0; font: var(--pt-detail); color: var(--text3); }
  img, video { max-width: 100%; border-radius: 8px; }
  iframe { width: 100%; height: 70vh; border: none; background: #fff; border-radius: 8px; }
  audio { width: 100%; }
  .spinner { margin: 60px auto; width: 26px; height: 26px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
