<script lang="ts">
  // A row that leads to another Settings page or flow (the Mac's `SettingsLinkRow` in `SettingsBlocks.swift`): an
  // optional section tile, title with optional detail line under it, status mark only when not done, and a chevron.
  import { emit } from "@tauri-apps/api/event";
  import Ico from "../../components/ui/Ico.svelte";
  import type { SettingsSectionId } from "../../lib/settings-pages";
  import { linkRowStateMeta, type LinkRowState } from "../../lib/settings-ui";
  import SettingsTile from "./SettingsTile.svelte";

  let {
    title,
    detail = null,
    section,
    icon,
    to,
    state = null,
    flush = false,
    onclick,
  }: {
    title: string;
    detail?: string | null;
    /** Settings section whose tile sits on the left (and default destination if `to`/`onclick` are omitted). */
    section?: SettingsSectionId;
    /** Explicit Lucide icon for rows without a Settings section of their own. */
    icon?: string;
    /** Destination Settings section when `onclick` is not provided. */
    to?: SettingsSectionId;
    /** Quiet when `"done"` or omitted; `"todo"`, `"warning"`, or `"error"` draws a state mark. */
    state?: LinkRowState | null;
    /** Edge-to-edge card row with hover fill (used in Overview's "At a glance" card). */
    flush?: boolean;
    onclick?: () => void;
  } = $props();

  const meta = $derived(linkRowStateMeta(state));
  const showTile = $derived(Boolean(section || icon));

  function activate() {
    if (onclick) {
      onclick();
      return;
    }
    const target = to ?? section;
    if (target) emit("navigate", `settings:${target}`).catch(() => {});
  }
</script>

<button type="button" class="row link-row" class:flush onclick={activate}>
  {#if showTile}
    <SettingsTile {section} {icon} size={26} />
  {/if}
  <span class="text">
    <span class="title">{title}</span>
    {#if detail}
      <span class="detail" class:warning={meta.detailTone === "warning"} class:error={meta.detailTone === "error"}>{detail}</span>
    {/if}
  </span>
  {#if meta.showIcon && meta.icon}
    <span class="state {meta.tone}" aria-hidden="true">
      <Ico name={meta.icon} size={meta.iconSize} stroke={meta.iconStroke} />
    </span>
  {/if}
  <span class="go" aria-hidden="true"><Ico name="chevron-right" size={12} /></span>
</button>

<style>
  .link-row {
    width: 100%;
    flex-wrap: nowrap;
    justify-content: flex-start;
    gap: var(--space-12);
    border: none;
    border-bottom: 1px solid var(--separator);
    border-radius: 0;
    background: none;
    text-align: left;
    color: var(--text2);
  }
  .link-row:last-child { border-bottom: none; }
  .link-row:hover:not(:disabled) { background: none; color: var(--paper); }
  .link-row.flush { padding: var(--space-12) var(--space-16); }
  .link-row.flush:hover:not(:disabled) { background: var(--row-hover); }
  /* Override `.settings .row > span:first-child` so the 26 px tile keeps its square size. */
  .link-row > :global(.settings-tile:first-child) { flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); text-align: left; }
  .title { font: var(--text-body); line-height: 1.3; color: var(--paper); }
  .detail {
    font: var(--text-detail);
    line-height: 1.3;
    color: var(--text2);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .detail.warning { color: var(--amber); }
  .detail.error { color: var(--coral); }
  .state { display: grid; place-items: center; flex: none; }
  .state.todo { color: var(--text2); }
  .state.warning { color: var(--amber); }
  .state.error { color: var(--coral); }
  .go { display: grid; place-items: center; flex: none; color: var(--text3); }
</style>
