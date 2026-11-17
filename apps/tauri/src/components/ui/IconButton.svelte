<script lang="ts">
  // A square symbol button in the `NookIconButton` look: quiet at rest, a soft fill under the pointer, its name as the
  // fast tooltip and for screen readers. The copy, refresh and tab-close buttons are built on it.
  import type { Snippet } from "svelte";
  import { tip } from "./tip";
  let { title, onclick, disabled = false, size = 26, children, class: klass = "" }: {
    title: string; onclick: (e: MouseEvent) => void; disabled?: boolean; size?: number; children: Snippet; class?: string;
  } = $props();
</script>

<button class="icon-button {klass}" style:width="{size}px" style:height="{size}px" {disabled} aria-label={title} use:tip={title} {onclick}>{@render children()}</button>

<style>
  .icon-button { display: inline-flex; align-items: center; justify-content: center; padding: 0; flex: none; background: transparent; border: none; border-radius: var(--radius-control); color: var(--text2); }
  .icon-button:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
</style>
