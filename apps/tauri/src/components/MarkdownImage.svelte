<script lang="ts">
  // A standalone image in an answer (`![alt](src)` on its own line, `MarkdownImageBlock` on the Mac):
  // loads web images directly, local paths through `readAnswerImage`, zooms on click, and shows a quiet chip if missing.
  import { api } from "../lib/api";
  import { tr } from "../lib/i18n.svelte";
  import Icon from "./Icon.svelte";

  let {
    alt,
    source,
    baseFolder = null,
  }: {
    alt: string;
    source: string;
    baseFolder?: string | null;
  } = $props();

  let resolvedSrc = $state<string | null>(null);
  let missing = $state(false);
  let enlarged = $state(false);

  const label = $derived(alt.trim() || source.split(/[\\/]/).pop() || source);

  function isDirectWebImage(src: string): boolean {
    const lower = src.toLowerCase();
    if (lower.startsWith("https://") || lower.startsWith("data:image/")) return true;
    return lower.startsWith("http://localhost") || lower.startsWith("http://127.0.0.1");
  }

  $effect(() => {
    const src = source;
    const base = baseFolder;
    enlarged = false;
    if (isDirectWebImage(src)) {
      resolvedSrc = src;
      missing = false;
      return;
    }
    if (src.toLowerCase().startsWith("http://")) {
      // Plain remote HTTP is blocked by CSP; keep missing chip rather than leaking mixed content.
      resolvedSrc = null;
      missing = true;
      return;
    }
    let cancelled = false;
    resolvedSrc = null;
    missing = false;
    api
      .readAnswerImage(src, base)
      .then((dataUri) => {
        if (cancelled) return;
        if (dataUri) {
          resolvedSrc = dataUri;
          missing = false;
        } else {
          resolvedSrc = null;
          missing = true;
        }
      })
      .catch(() => {
        if (cancelled) return;
        resolvedSrc = null;
        missing = true;
      });
    return () => {
      cancelled = true;
    };
  });
</script>

{#if missing}
  <div class="img-chip" title={source}>
    <Icon name="image" size={14} />
    <span>{label}</span>
  </div>
{:else if resolvedSrc}
  {@const toggleLabel = enlarged ? tr("Verkleinen", "Shrink") : tr("Vergroten", "Enlarge")}
  <button
    type="button"
    class="img-btn"
    aria-pressed={enlarged}
    aria-label={alt || toggleLabel}
    title={alt || source}
    onclick={() => (enlarged = !enlarged)}
  >
    <img
      class="md-img"
      class:enlarged
      src={resolvedSrc}
      {alt}
      onerror={() => {
        resolvedSrc = null;
        missing = true;
      }}
    />
  </button>
{/if}

<style>
  .img-btn {
    display: inline-flex;
    max-width: 100%;
    padding: 0;
    margin: 4px 0 8px;
    border: none;
    background: transparent;
    border-radius: 10px;
  }
  .md-img {
    display: block;
    max-width: min(100%, 360px);
    max-height: 260px;
    border-radius: 10px;
    cursor: zoom-in;
    object-fit: contain;
    transition: max-width 0.2s ease, max-height 0.2s ease;
  }
  .md-img.enlarged {
    max-width: min(100%, 640px);
    max-height: 480px;
    cursor: zoom-out;
  }
  .img-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin: 4px 0 8px;
    padding: 6px 10px;
    border-radius: var(--radius-chip);
    background: var(--smoke);
    color: var(--text2);
    font-size: 12px;
    max-width: 100%;
  }
  .img-chip span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
