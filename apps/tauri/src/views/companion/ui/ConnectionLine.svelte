<script lang="ts">
  // Under the header of every tab (`ConnectionLine`): why the computer cannot be reached, once it has been away a moment.
  import { tr } from "../../../lib/i18n.svelte";
  import type { ClientView } from "../../../lib/companion";
  import Ico from "./Ico.svelte";
  let { view }: { view: ClientView } = $props();
  let away = $state(false);
  $effect(() => {
    if (view.phase !== "offline") return void (away = false);
    const timer = setTimeout(() => (away = true), 800);
    return () => clearTimeout(timer);
  });
</script>

{#if away}
  <div class="line">
    <Ico name="wifi-off" size={13} stroke={2.2} />
    <span class="text"><span>{view.reason || tr("Zoeken naar je Mac…", "Looking for your Mac…")}</span></span>
  </div>
{/if}

<style>
  .line { display: flex; align-items: baseline; gap: 6px; padding: 0 4px; font: var(--pt-detail); color: var(--text2); animation: in 250ms ease-out; }
  .line :global(svg) { position: relative; top: 2px; }
  .text { display: flex; flex-direction: column; gap: 2px; }
  @keyframes in { from { opacity: 0; } }
</style>
