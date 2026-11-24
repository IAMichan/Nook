<script lang="ts">
  // A page the agent shows in its timeline (`RenderedPageRow` on the Mac): a work line with its title that folds the
  // page away, and the page in a sandboxed frame at the height it asked for. The frame runs the page's own scripts but
  // cannot reach the network, Nook or the window: no same origin, no forms, popups or navigation, and a content policy
  // on top (`session_cards::sandboxed`).
  import { tr } from "../../../lib/i18n.svelte";
  import type { RunEvent, WorkspaceRun } from "../../../lib/workspace/api";
  import { pageHeight, sessionCardsApi } from "../../../lib/workspace/session-cards";
  import Ico from "../../../components/ui/Ico.svelte";
  import DisclosureChevron from "../../../components/ui/DisclosureChevron.svelte";

  let { run, event }: { run: WorkspaceRun; event: RunEvent } = $props();
  let html = $state<string | null>(null);
  let missing = $state(false);
  let hidden = $state(false);
  const height = $derived(pageHeight(event));
  const title = $derived(event.text || tr("Pagina", "Page"));

  $effect(() => {
    let stale = false;
    sessionCardsApi
      .pageHtml(run.id, event.id)
      .then((h) => { if (!stale) html = h; })
      .catch(() => { if (!stale) missing = true; });
    return () => { stale = true; };
  });
</script>

<div class="page">
  <button type="button" class="work-line" aria-expanded={!hidden} onclick={() => (hidden = !hidden)}>
    <span class="work-icon"><Ico name="app-window-mac" size={16} stroke={1.8} /></span>
    <span class="label">{title}</span>
    <DisclosureChevron open={!hidden} size={10} />
  </button>
  {#if !hidden}
    {#if html !== null}
      <iframe {title} sandbox="allow-scripts" srcdoc={html} style:height="{height}px" referrerpolicy="no-referrer"></iframe>
    {:else if missing}
      <p class="gone">{tr("Deze pagina is er niet meer.", "This page is no longer there.")}</p>
    {:else}
      <div class="room" style:height="{height}px"></div>
    {/if}
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-2) 0; }
  .work-line { all: unset; cursor: pointer; display: flex; gap: var(--space-8); align-items: center; min-height: 24px; font: var(--text-body); color: var(--text2); }
  .work-line:focus-visible { outline: 2px solid var(--iris); outline-offset: 2px; border-radius: var(--radius-chip); }
  .work-icon { display: inline-flex; width: 16px; justify-content: center; flex: none; color: var(--text3); }
  .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  iframe, .room, .gone { margin-left: 24px; }
  iframe { display: block; width: calc(100% - 24px); border: 1px solid var(--line2); border-radius: var(--radius-control); background: transparent; }
  .gone { margin-top: 0; margin-bottom: 0; font: var(--text-detail); color: var(--text3); }
</style>
