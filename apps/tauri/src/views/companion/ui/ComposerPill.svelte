<script lang="ts">
  // A quiet choice in a composer's row (`ComposerPill`): an optional mark, a word, and a chevron when it opens a menu.
  import type { Snippet } from "svelte";
  import Ico from "./Ico.svelte";
  let { label, icon, lead, chevron = true, on = false, tint, onclick }: {
    label: string; icon?: string; lead?: Snippet; chevron?: boolean; on?: boolean; tint?: string; onclick: (e: MouseEvent) => void;
  } = $props();
</script>

<button class="pill press" class:on style:color={tint} onclick={(e) => { e.stopPropagation(); onclick(e); }}>
  {#if lead}{@render lead()}{:else if icon}<Ico name={icon} size={13} stroke={2} />{/if}
  <span>{label}</span>
  {#if chevron}<span class="chev"><Ico name="chevron-down" size={10} stroke={3} /></span>{/if}
</button>

<style>
  .pill { display: inline-flex; align-items: center; gap: 6px; padding: 0 8px; height: 32px; font: var(--pt-label) !important; color: var(--text2); border-radius: 8px; white-space: nowrap; min-width: 0; }
  .pill span { overflow: hidden; text-overflow: ellipsis; }
  .pill.on { background: var(--smoke) !important; color: var(--paper); }
  .chev { opacity: 0.6; display: inline-flex; }
</style>
