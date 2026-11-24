<script lang="ts" module>
  // The GIFs you sent lately, newest first, for the stickers shelf ("the ones you send show here next time").
  export interface SentGif { id: string; preview: string; file: string; title: string }
  const RECENT = "chats.recentGifs";
  export function recentGifs(): SentGif[] {
    try {
      return JSON.parse(localStorage.getItem(RECENT) ?? "[]") as SentGif[];
    } catch {
      return [];
    }
  }
  export function rememberGif(gif: SentGif) {
    const list = [gif, ...recentGifs().filter((g) => g.id !== gif.id)].slice(0, 24);
    localStorage.setItem(RECENT, JSON.stringify(list));
  }
</script>

<script lang="ts">
  // GIFs above the chat's field (`ChatGIFShelf`, `ChatStickerShelf` on the Mac): GIPHY's trending ones when it opens and a
  // search, or (as `stickers`) the ones you sent lately; a click sends the GIF at once, as WhatsApp does. "GIF from file…"
  // takes one of your own. Only the search words go to GIPHY; the file is fetched by Nook from GIPHY itself.
  import { invoke } from "@tauri-apps/api/core";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import IconButton from "../../components/ui/IconButton.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import Spinner from "../../components/ui/Spinner.svelte";

  interface Gif { id: string; title: string; preview: string; width: number | null; height: number | null; file: string }

  let { kind, onsend, onfile, onclose, onsettings }: {
    kind: "gifs" | "stickers";
    onsend: (name: string, mime: string, base64: string) => Promise<void>;
    onfile: (files: FileList | null) => void;
    onclose: () => void;
    onsettings: () => void;
  } = $props();

  let query = $state("");
  let gifs = $state<Gif[]>([]);
  let problem = $state<string | null>(null);
  let loading = $state(false);
  let fetching = $state<string | null>(null);
  let picker = $state<HTMLInputElement | null>(null);
  const recent = $state(recentGifs());

  // A newer search wins: the answer to an older one is dropped.
  let asked = 0;
  $effect(() => {
    if (kind !== "gifs") return;
    const words = query;
    const mine = ++asked;
    const timer = setTimeout(async () => {
      loading = true;
      try {
        const page = await invoke<{ gifs: Gif[]; problem: string | null }>("chat_gifs", { query: words, offset: 0 });
        if (mine !== asked) return;
        gifs = page.gifs;
        problem = page.problem;
      } catch (e) {
        if (mine === asked) problem = String(e);
      } finally {
        if (mine === asked) loading = false;
      }
    }, words ? 300 : 0);
    return () => clearTimeout(timer);
  });

  async function pick(gif: { id: string; preview: string; file: string; title: string }) {
    if (fetching) return;
    fetching = gif.id;
    try {
      const file = await invoke<{ name: string; mime: string; base64: string }>("chat_gif_file", { file: gif.file });
      await onsend(file.name, file.mime, file.base64);
      rememberGif({ id: gif.id, preview: gif.preview, file: gif.file, title: gif.title });
      onclose();
    } catch (e) {
      problem = String(e);
    } finally {
      fetching = null;
    }
  }

  const shown = $derived(kind === "gifs" ? gifs : recent);
</script>

<div class="panel" role="dialog" aria-label={kind === "gifs" ? tr("GIF", "GIF") : tr("Stickers en GIF's", "Stickers and GIFs")}>
  <div class="head">
    <Ico name={kind === "gifs" ? "file-video" : "smile"} size={13} />
    <span class="title">{kind === "gifs" ? tr("GIF", "GIF") : tr("Stickers en GIF's", "Stickers and GIFs")}</span>
    <IconButton title={tr("Sluiten", "Close")} size={22} onclick={onclose}><Ico name="x" size={11} stroke={2.4} /></IconButton>
  </div>
  {#if kind === "gifs"}
    <div class="search"><SearchField bind:value={query} placeholder={tr("Zoek GIF's op GIPHY", "Search GIPHY")} /></div>
  {/if}
  {#if kind === "stickers" && !recent.length}
    <p class="note">{tr("Nog geen stickers of GIF's. Kies er een uit een bestand; wat je verstuurt, staat hier de volgende keer.", "No stickers or GIFs yet. Pick one from a file; the ones you send show here next time.")}</p>
  {:else if problem && !shown.length}
    <p class="note">{problem}</p>
    {#if kind === "gifs" && !loading}<button class="small-ghost" onclick={onsettings}>{tr("GIPHY-sleutel toevoegen", "Add GIPHY key")}</button>{/if}
  {:else if loading && !shown.length}
    <div class="note"><Spinner /></div>
  {:else}
    <div class="grid">
      {#each shown as g (g.id)}
        <button class="cell" title={g.title || tr("GIF", "GIF")} aria-label={g.title || tr("GIF", "GIF")} disabled={!!fetching} onclick={() => pick(g)}>
          <img src={g.preview} alt="" loading="lazy" />
          {#if fetching === g.id}<span class="busy"><Spinner /></span>{/if}
        </button>
      {/each}
    </div>
  {/if}
  <div class="foot">
    <button class="small-ghost" onclick={() => picker?.click()}>{tr("GIF uit bestand…", "GIF from file…")}</button>
    <input class="hidden" type="file" accept="image/gif,video/mp4" bind:this={picker} onchange={(e) => { onfile((e.currentTarget as HTMLInputElement).files); onclose(); }} />
    {#if kind === "gifs"}<span class="powered">{tr("Powered by GIPHY", "Powered by GIPHY")}</span>{/if}
  </div>
</div>

<style>
  .panel { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8); border: 1px solid var(--field-stroke); border-radius: var(--radius-sheet); background: var(--composer-tray); }
  .head { display: flex; align-items: center; gap: var(--space-6); color: var(--text2); }
  .title { flex: 1; font: var(--text-label); color: var(--paper); }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(92px, 1fr)); gap: var(--space-4); max-height: 220px; overflow-y: auto; }
  .cell { position: relative; padding: 0; height: 80px; border: 0; border-radius: var(--radius-control); overflow: hidden; background: var(--surface); }
  .cell img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .cell:hover:not(:disabled) { outline: 2px solid var(--mint); }
  .busy { position: absolute; inset: 0; display: grid; place-items: center; background: color-mix(in srgb, var(--ink) 50%, transparent); color: var(--paper); }
  .note { margin: 0; font: var(--text-detail); color: var(--text3); }
  .foot { display: flex; align-items: center; justify-content: space-between; }
  .powered { font: var(--text-detail); color: var(--text3); }
  .small-ghost { height: 26px; padding: 0 var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); font: var(--text-label); white-space: nowrap; align-self: flex-start; }
  .small-ghost:hover { background: var(--row-hover); color: var(--paper); }
  .hidden { display: none; }
</style>
