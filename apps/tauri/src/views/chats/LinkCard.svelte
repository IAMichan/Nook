<script lang="ts">
  // What a link in a message shows (`ChatLinkPreview`): a picture link as the picture; a page as a card with its picture
  // (16:9, with a play mark for a video page), its site with its icon, and its title. Fetched once the bubble is drawn,
  // through Rust (public addresses only); a click opens the link in the browser.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { chatsApi } from "../../lib/connectors";
  import Ico from "../../components/ui/Ico.svelte";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";

  let { url }: { url: string } = $props();
  let preview = $state<{ title: string | null; image: string | null; video: boolean } | null | undefined>(undefined);
  $effect(() => {
    void url;
    preview = undefined;
    chatsApi.linkPreview(url).then((p) => (preview = p)).catch(() => (preview = null));
  });
  const host = $derived.by(() => {
    try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return url; }
  });
  const picture = $derived(/\.(jpe?g|png|gif|webp|heic|bmp)(\?|$)/i.test(url));
</script>

{#if picture}
  {#if preview?.image}
    <button class="picture" title={url} onclick={() => openUrl(url).catch(() => {})}><img src={preview.image} alt={host} /></button>
  {:else}
    <button class="slim" title={url} onclick={() => openUrl(url).catch(() => {})}><Ico name="link" size={12} />{host}</button>
  {/if}
{:else if preview !== null}
  <button class="card" title={url} aria-label={preview?.title ? `${preview.title}, ${host}` : host} onclick={() => openUrl(url).catch(() => {})}>
    {#if preview === undefined}
      <span class="frame" aria-hidden="true"></span>
    {:else if preview.image}
      <span class="frame"><img src={preview.image} alt="" />{#if preview.video}<span class="play"><Ico name="play" size={18} fill="currentColor" /></span>{/if}</span>
    {/if}
    <span class="caption">
      <span class="site"><ServiceIcon domain={host} title={host} size={12} /><span>{host}</span></span>
      {#if preview?.title}<span class="title">{preview.title}</span>{/if}
    </span>
  </button>
{/if}

<style>
  .card { display: flex; flex-direction: column; width: 280px; max-width: 100%; padding: 0; overflow: hidden; text-align: left; border: 1px solid var(--hairline); border-radius: var(--radius-card); background: color-mix(in srgb, var(--ink) 32%, transparent); color: inherit; }
  .card:hover:not(:disabled) { background: color-mix(in srgb, var(--ink) 45%, transparent); border-color: var(--hairline); }
  .frame { position: relative; display: block; aspect-ratio: 16 / 9; overflow: hidden; }
  .frame img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .play { position: absolute; inset: 0; margin: auto; width: 40px; height: 40px; display: grid; place-items: center; border-radius: 50%; background: color-mix(in srgb, var(--ink) 55%, transparent); color: var(--paper); }
  .caption { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-6) var(--space-8); }
  .site { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-caption); color: var(--text3); }
  .site :global(.tile) { border-radius: var(--radius-chip) !important; }
  .title { font: var(--text-emphasis); line-height: 1.3; color: var(--paper); overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .picture { padding: 0; border: 0; background: none; cursor: zoom-in; display: block; }
  .picture img { display: block; max-width: 300px; max-height: 240px; border-radius: var(--radius-card); object-fit: cover; }
  .slim { display: inline-flex; align-items: center; gap: var(--space-4); padding: var(--space-2) var(--space-6); border: 0; border-radius: var(--radius-chip); background: color-mix(in srgb, var(--ink) 32%, transparent); font: var(--text-caption); color: var(--text2); }
</style>
