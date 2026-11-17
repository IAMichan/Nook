<script lang="ts">
  // What a citation rests on (`CitationPreview` on the Mac): per source its icon, origin, short title, an Open button
  // when a link exists, and the matching excerpt lines with a bright accent bar on lines backing the sentence.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { isOpenableUrl, pickPassage, referenceOrigin, referenceShortTitle } from "../lib/citations";
  import { tr } from "../lib/i18n.svelte";
  import { sourceGlyphSvg } from "../lib/service-icons";
  import { sourceDomain } from "../lib/sources";
  import type { SourceReference } from "../lib/types";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";

  let {
    references,
    claim = "",
    anchor,
    edge = "bottom",
    onhover,
    onopen,
  }: {
    references: SourceReference[];
    claim?: string;
    anchor: { left: number; top: number; right: number; bottom: number };
    edge?: "bottom" | "right";
    onhover?: (inside: boolean) => void;
    onopen?: () => void;
  } = $props();

  let box = $state<HTMLDivElement | null>(null);
  let pos = $state<{ left: number; top: number }>({ left: 12, top: 12 });

  function updatePosition() {
    const width = box?.offsetWidth || 340;
    const height = box?.offsetHeight || 200;
    const vw = typeof window !== "undefined" ? window.innerWidth : 800;
    const vh = typeof window !== "undefined" ? window.innerHeight : 600;
    const pad = 12;
    let left: number;
    let top: number;
    if (edge === "right") {
      left = anchor.right + 8;
      if (left + width > vw - pad) left = Math.max(pad, anchor.left - width - 8);
      if (left + width > vw - pad) left = Math.max(pad, Math.min(anchor.left, vw - width - pad));
      top = Math.max(pad, Math.min(anchor.top - 8, vh - height - pad));
    } else {
      left = Math.max(pad, Math.min(anchor.left, vw - width - pad));
      top = anchor.bottom + 6;
      if (top + height > vh - pad && anchor.top - height - 6 >= pad) {
        top = anchor.top - height - 6;
      } else {
        top = Math.max(pad, Math.min(top, vh - height - pad));
      }
    }
    pos = { left: Math.round(left), top: Math.round(top) };
  }

  $effect(() => {
    void references;
    void claim;
    void anchor;
    void edge;
    updatePosition();
    const raf = requestAnimationFrame(updatePosition);
    return () => cancelAnimationFrame(raf);
  });

  function open(ref: SourceReference) {
    if (ref.url && isOpenableUrl(ref.url)) {
      openUrl(ref.url);
      onopen?.();
    }
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  bind:this={box}
  class="citation-popover"
  role="dialog"
  tabindex="-1"
  aria-label={references[0]?.title ?? tr("Bron", "Source")}
  style="left:{pos.left}px;top:{pos.top}px"
  onmouseenter={() => onhover?.(true)}
  onmouseleave={() => onhover?.(false)}
>
  {#each references.slice(0, 3) as ref, idx (ref.number)}
    {@const domain = sourceDomain(ref.sourceId)}
    {@const openable = isOpenableUrl(ref.url)}
    {@const lines = pickPassage(ref.excerpt, claim, referenceShortTitle(ref))}
    {#if idx > 0}<div class="divider"></div>{/if}
    <div class="source">
      <div class="head">
        {#if domain}
          <ServiceIcon {domain} title={referenceOrigin(ref) || ref.sourceId} size={14} />
        {:else}
          <span class="glyph" aria-hidden="true">{@html sourceGlyphSvg(ref.sourceId)}</span>
        {/if}
        <span class="origin">{referenceOrigin(ref)}</span>
        {#if openable}
          <button
            type="button"
            class="open-btn"
            title={tr("Open het origineel", "Open the original")}
            onclick={() => open(ref)}
          >
            {tr("Openen", "Open")}
          </button>
        {/if}
      </div>
      <div class="title">{referenceShortTitle(ref)}</div>
      {#if lines.length === 0}
        <p class="empty">
          {tr(
            "Nook heeft de tekst van deze bron bij dit antwoord niet bewaard. Stel de vraag opnieuw om hem te zien.",
            "Nook did not keep this source's text for this answer. Ask again to see it.",
          )}
        </p>
      {:else}
        <div class="passage">
          {#each lines as line, i (i)}
            <div class="line" class:relevant={line.relevant}>{line.text}</div>
          {/each}
        </div>
      {/if}
    </div>
  {/each}
  {#if references.length > 3}
    <div class="more">{tr("En nog {n} bronnen", "And {n} more sources", { n: references.length - 3 })}</div>
  {/if}
</div>

<style>
  .citation-popover {
    position: fixed;
    z-index: 60;
    width: min(340px, calc(100vw - 24px));
    max-height: min(420px, calc(100vh - 24px));
    overflow-y: auto;
    padding: 12px 14px;
    border-radius: var(--radius-panel);
    background: var(--graphite);
    border: 1px solid var(--line2);
    box-shadow: var(--shadow-popover);
    display: flex;
    flex-direction: column;
    gap: 10px;
    text-align: left;
    line-height: 1.45;
  }
  .divider {
    height: 1px;
    background: color-mix(in srgb, var(--line2) 75%, transparent);
  }
  .source {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
  }
  .glyph {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: var(--text2);
    flex: none;
  }
  .origin {
    flex: 1;
    min-width: 0;
    font: var(--text-label);
    color: var(--text3);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .open-btn {
    flex: none;
    font: var(--text-label);
    font-weight: 500;
    padding: 2px 8px;
    border-radius: var(--radius-control);
    border: none;
    background: var(--smoke);
    color: var(--paper);
  }
  .open-btn:hover {
    filter: brightness(1.1);
  }
  .title {
    font: var(--text-detail);
    font-weight: 600;
    color: var(--paper);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .empty {
    margin: 0;
    font: var(--text-detail);
    color: var(--text3);
  }
  .passage {
    display: flex;
    flex-direction: column;
    gap: 4px;
    user-select: text;
  }
  .line {
    position: relative;
    padding-left: 10px;
    font: var(--text-detail);
    color: var(--text3);
    overflow-wrap: anywhere;
  }
  .line::before {
    content: "";
    position: absolute;
    left: 0;
    top: 2px;
    bottom: 2px;
    width: 2px;
    border-radius: 999px;
    background: var(--line2);
  }
  .line.relevant {
    color: var(--paper);
  }
  .line.relevant::before {
    background: var(--iris);
  }
  .more {
    font: var(--text-label);
    color: var(--text3);
  }
</style>
