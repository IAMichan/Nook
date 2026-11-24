<script lang="ts">
  // The file preview over the window (the Mac's `FilePreviewWindow`): a photo, a PDF, a video or a sound file, its name
  // and size in the header, "Open in app" and close. Escape or a click beside it closes it.
  import { invoke } from "@tauri-apps/api/core";
  import { tr } from "../lib/i18n.svelte";
  import { PREVIEW_EVENT, preview } from "../lib/file-preview.svelte";
  import { toast } from "../lib/toast.svelte";
  import Ico from "./ui/Ico.svelte";
  import IconButton from "./ui/IconButton.svelte";

  interface FilePreview { path: string; name: string; kind: "image" | "pdf" | "video" | "audio" | "other"; mediaType: string; size: number; base64: string | null }

  let file = $state<FilePreview | null>(null);
  let url = $state<string | null>(null);
  let failed = $state<string | null>(null);

  $effect(() => {
    const take = (e: Event) => { const path = (e as CustomEvent<string>).detail; if (typeof path === "string") preview.open(path); };
    window.addEventListener(PREVIEW_EVENT, take);
    return () => window.removeEventListener(PREVIEW_EVENT, take);
  });

  $effect(() => {
    const path = preview.path;
    file = null;
    failed = null;
    if (!path) return;
    let made: string | null = null;
    let gone = false;
    invoke<FilePreview>("file_preview", { path }).then((f) => {
      if (gone) return;
      file = f;
      if (f.base64) {
        const bytes = Uint8Array.from(atob(f.base64), (c) => c.charCodeAt(0));
        made = URL.createObjectURL(new Blob([bytes], { type: f.mediaType }));
        url = made;
      }
    }).catch((e) => (failed = String(e)));
    return () => {
      gone = true;
      if (made) URL.revokeObjectURL(made);
      url = null;
    };
  });

  $effect(() => {
    if (!preview.path) return;
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); preview.close(); } };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });

  async function openInApp() {
    const path = file?.path ?? preview.path;
    if (!path) return;
    try { await invoke("file_open_in_app", { path }); preview.close(); }
    catch (e) { toast.error(tr("Kon het bestand niet openen", "Could not open the file"), e); }
  }

  const size = (n: number) => (n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`);
  const name = $derived(file?.name ?? preview.path?.split(/[\\/]/).pop() ?? "");
</script>

{#if preview.path}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="scrim" onclick={() => preview.close()}>
    <div class="window" role="dialog" aria-modal="true" aria-label={name} tabindex="-1" onclick={(e) => e.stopPropagation()}>
      <header>
        <span class="name" title={file?.path}>{name}</span>
        {#if file}<span class="size">{size(file.size)}</span>{/if}
        <span class="spacer"></span>
        <button class="open" onclick={openInApp}><Ico name="external-link" size={13} />{tr("Open in app", "Open in app")}</button>
        <IconButton title={tr("Sluit", "Close")} size={26} onclick={() => preview.close()}><Ico name="x" size={13} /></IconButton>
      </header>
      <div class="body">
        {#if failed}
          <p class="note">{failed}</p>
        {:else if !file}
          <p class="note">{tr("Laden…", "Loading…")}</p>
        {:else if !url}
          <p class="note">{file.kind === "other" ? tr("Nook kan dit bestand niet tonen; open het in zijn app.", "Nook can't show this file; open it in its app.") : tr("Dit bestand is te groot om hier te tonen; open het in zijn app.", "This file is too large to show here; open it in its app.")}</p>
        {:else if file.kind === "image"}
          <img src={url} alt={file.name} />
        {:else if file.kind === "pdf"}
          <iframe src={url} title={file.name}></iframe>
        {:else if file.kind === "video"}
          <!-- svelte-ignore a11y_media_has_caption -->
          <video src={url} controls autoplay></video>
        {:else}
          <audio src={url} controls autoplay></audio>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .scrim { position: fixed; inset: 0; z-index: 85; display: grid; place-items: center; padding: var(--space-32); background: color-mix(in srgb, var(--ink) 72%, transparent); animation: fade var(--motion-quick, 160ms) ease-out; }
  .window { display: flex; flex-direction: column; width: min(1000px, 100%); height: min(760px, 100%); background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); overflow: hidden; }
  header { display: flex; align-items: center; gap: var(--space-8); min-height: 44px; padding: 0 var(--space-8) 0 var(--space-16); border-bottom: 1px solid var(--hairline); }
  .name { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .size { font: var(--text-detail); color: var(--text3); flex: none; }
  .spacer { flex: 1; }
  .open { display: inline-flex; align-items: center; gap: var(--space-6); padding: var(--space-4) var(--space-8); border: 0; border-radius: var(--radius-control); background: var(--smoke); color: var(--paper); font: var(--text-control); flex: none; }
  .body { flex: 1; min-height: 0; display: grid; place-items: center; background: var(--canvas); }
  img, video { max-width: 100%; max-height: 100%; object-fit: contain; }
  iframe { width: 100%; height: 100%; border: 0; background: var(--paper); }
  .note { margin: 0; padding: var(--space-24); font: var(--text-body); color: var(--text2); text-align: center; }
  @keyframes fade { from { opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .scrim { animation: none; } }
</style>
