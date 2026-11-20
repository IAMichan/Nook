<script lang="ts">
  // The head of a page in the Agents area (Pull requests, Actions, All terminals): its title on the left in the window's
  // top row, and the page's own icon buttons on the right, clear of the window's buttons on Windows.
  import type { Snippet } from "svelte";

  /** `flush`: the page around it already has the page's side padding. */
  let { title, flush = false, children }: { title: string; flush?: boolean; children?: Snippet } = $props();
</script>

<header class="page-head" class:flush data-tauri-drag-region>
  <h1>{title}</h1>
  <span class="spacer" data-tauri-drag-region></span>
  {@render children?.()}
</header>

<style>
  .page-head {
    display: flex; align-items: center; gap: var(--space-4); min-height: 52px; flex: none;
    padding: 0 calc(var(--space-16) + var(--caption-room, 0px)) 0 calc(var(--space-24) + var(--space-6));
  }
  .page-head.flush { padding: 0 var(--caption-room, 0px) 0 0; }
  :global(.main.list-away) .page-head:not(.flush) { padding-left: calc(var(--space-8) + 28px + var(--space-16)); }
  h1 { margin: 0; font: var(--text-title); color: var(--paper); white-space: nowrap; }
  .spacer { flex: 1; }
  /* The page's buttons as the Mac's `ToolbarIconButton`. */
  .page-head :global(.page-icon) {
    display: grid; place-items: center; width: 28px; height: 28px; padding: 0; margin: 0; border: 0;
    border-radius: var(--radius-control); background: transparent; color: var(--text2);
  }
  .page-head :global(.page-icon:hover:not(:disabled)) { background: var(--smoke); color: var(--paper); }
  .page-head :global(.page-icon:disabled) { opacity: 0.4; }
</style>
