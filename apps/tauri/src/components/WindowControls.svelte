<script lang="ts">
  // The window's own title bar buttons on Windows. The Mac's main window has no title bar of its own: the sidebar's head
  // and the conversation's header fill the title bar's row, with the traffic lights in it (`PanelSidebarMetrics`). On
  // Windows the main window draws no system frame either (`platform::desktop::own_title_bar`), so minimize, maximize
  // and close sit here, in the top right corner where Windows keeps them, over the same 52 px row. Dragging that row
  // moves the window and a double-click maximizes it (`data-tauri-drag-region` on the headers).
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { tr } from "../lib/i18n.svelte";

  const win = getCurrentWindow();
  let maximized = $state(false);

  $effect(() => {
    const read = () => win.isMaximized().then((m) => (maximized = m)).catch(() => {});
    read();
    const off = win.onResized(read);
    return () => { off.then((f) => f()); };
  });

  const maximizeLabel = $derived(maximized ? tr("Herstellen", "Restore") : tr("Maximaliseren", "Maximize"));
</script>

<div class="controls" role="group" aria-label={tr("Venster", "Window")}>
  <button class="control" title={tr("Minimaliseren", "Minimize")} aria-label={tr("Minimaliseren", "Minimize")} onclick={() => win.minimize()}>
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M0 5h10" /></svg>
  </button>
  <button class="control" title={maximizeLabel} aria-label={maximizeLabel} onclick={() => win.toggleMaximize()}>
    {#if maximized}
      <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><rect x="0.5" y="2.5" width="7" height="7" rx="1" /><path d="M2.5 2.5V1.5a1 1 0 0 1 1-1h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1h-1" /></svg>
    {:else}
      <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><rect x="0.5" y="0.5" width="9" height="9" rx="1" /></svg>
    {/if}
  </button>
  <!-- Close hides the window, as the red light does on the Mac: Nook keeps running in the bar and the tray. -->
  <button class="control close" title={tr("Sluiten", "Close")} aria-label={tr("Sluiten", "Close")} onclick={() => win.close()}>
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M0.5 0.5l9 9M9.5 0.5l-9 9" /></svg>
  </button>
</div>

<style>
  .controls { position: fixed; top: 0; right: 0; z-index: 30; display: flex; height: var(--caption-height); }
  .control { display: grid; place-items: center; width: var(--caption-button); height: 100%; padding: 0; border: 0; border-radius: 0; background: transparent; color: var(--text2); }
  .control svg { fill: none; stroke: currentColor; stroke-width: 1; }
  .control:hover { background: var(--row-hover); color: var(--paper); }
  .control:active { background: var(--row-selected); }
  .control.close:hover, .control.close:active { background: var(--caption-close); color: var(--on-caption-close); }
  .control:focus-visible { outline: 2px solid var(--iris); outline-offset: -2px; }
</style>
