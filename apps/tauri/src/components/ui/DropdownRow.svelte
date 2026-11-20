<script lang="ts">
  // One choice in a dropdown (the Mac's `DropdownRow`): an icon or an agent's logo, a title, an optional description and
  // trailing text, a faint fill on the chosen row (no check mark), and a star for favorites that shows on hover.
  import Ico from "./Ico.svelte";
  import AgentMark from "../../views/companion/ui/AgentMark.svelte";
  import { tr } from "../../lib/i18n.svelte";

  let { symbol, brand, title, detail, trailing, chosen = false, highlighted = false, tint, favorite, onstar, disabledReason, onclick }: {
    symbol?: string;
    /** A name whose maker's mark goes in front (`BrandMark`). */
    brand?: string;
    title: string;
    detail?: string;
    trailing?: string;
    chosen?: boolean;
    highlighted?: boolean;
    tint?: string;
    /** The star: true while a favorite; undefined leaves it out. */
    favorite?: boolean;
    onstar?: () => void;
    disabledReason?: string;
    onclick: () => void;
  } = $props();
</script>

<div class="dd-row-wrap" class:has-star={favorite !== undefined}>
  <button class="dd-row" class:chosen={chosen && !highlighted} class:lit={highlighted} class:tall={!!detail} disabled={!!disabledReason}
    title={disabledReason} style:--tint={tint} onclick={onclick}>
    {#if brand}<span class="mark"><AgentMark agent={brand} size={14} /></span>
    {:else if symbol}<span class="mark sym"><Ico name={symbol} size={15} /></span>{/if}
    <span class="text">
      <span class="title">{title}</span>
      {#if detail}<span class="detail">{detail}</span>{/if}
    </span>
    {#if trailing}<span class="trailing">{trailing}</span>{/if}
    {#if favorite !== undefined}<span class="star-room"></span>{/if}
  </button>
  {#if favorite !== undefined}
    <button class="star" class:on={favorite} onclick={(e) => { e.stopPropagation(); onstar?.(); }}
      title={favorite ? tr("Uit favorieten", "Remove from favorites") : tr("Aan favorieten toevoegen", "Add to favorites")}
      aria-label={favorite ? tr("Uit favorieten", "Remove from favorites") : tr("Aan favorieten toevoegen", "Add to favorites")}>
      <Ico name="star" size={13} fill={favorite ? "currentColor" : "none"} />
    </button>
  {/if}
</div>

<style>
  .dd-row-wrap { position: relative; }
  .dd-row {
    display: flex; align-items: center; gap: var(--space-8); width: 100%; min-height: 30px; margin: 0;
    padding: var(--space-6) var(--space-8); border: 0; border-radius: var(--radius-chip); background: transparent;
    color: var(--tint, var(--paper)); text-align: left;
  }
  .dd-row.tall { align-items: flex-start; padding: var(--space-8); }
  .dd-row:hover:not(:disabled), .dd-row.lit { background: var(--smoke); }
  .dd-row.chosen { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .dd-row:disabled { opacity: 0.64; cursor: default; }
  .mark { display: inline-flex; flex: none; width: 15px; justify-content: center; }
  .tall .mark { padding-top: 2px; }
  .sym { color: var(--tint, var(--text2)); }
  .text { display: flex; flex-direction: column; gap: var(--space-2); flex: 1; min-width: 0; }
  .title { font: var(--text-body); color: inherit; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .detail { font: var(--text-detail); color: var(--text3); }
  .trailing { font: var(--text-detail); color: var(--text3); white-space: nowrap; }
  .star-room { width: 14px; flex: none; }
  .star {
    position: absolute; top: 50%; right: var(--space-4); transform: translateY(-50%); display: none; place-items: center;
    width: 22px; height: 22px; padding: 0; margin: 0; border: 0; background: transparent; color: var(--text3);
  }
  .star.on { display: grid; color: var(--paper); }
  .dd-row-wrap:hover .star { display: grid; }
</style>
