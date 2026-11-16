<script lang="ts">
  // The top of every tab (`PanelHeader`): Nook's orb (the computer's menu; an amber dot while it cannot be reached),
  // the tab's name with how the phone reaches the computer under it, the tab's own buttons, and the gear (Settings) —
  // or a close button inside a sheet.
  import type { Snippet } from "svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import NookMark from "./NookMark.svelte";
  import IconButton from "./IconButton.svelte";
  import ConnectionTitle from "./ConnectionTitle.svelte";
  import type { ClientView } from "../../../lib/companion";

  let { title, view, onorb, ongear, onclose, buttons }: {
    title: string;
    view: ClientView;
    onorb?: () => void;
    ongear?: () => void;
    onclose?: () => void;
    buttons?: Snippet;
  } = $props();
  let mark = $state<NookMark | null>(null);
</script>

<header>
  <button class="orb" aria-label={tr("Nook en je Mac", "Nook and your Mac")} onclick={() => { mark?.poke(); onorb?.(); }}>
    <NookMark bind:this={mark} size={30} />
    {#if view.phase === "offline"}<span class="away"></span>{/if}
  </button>
  <div class="titles">
    <h1>{title}</h1>
    <ConnectionTitle {view} />
  </div>
  {@render buttons?.()}
  {#if onclose}
    <IconButton icon="x" label={tr("Sluit", "Close")} onclick={onclose} />
  {:else if ongear}
    <IconButton icon="settings" label={tr("Instellingen", "Settings")} onclick={ongear} />
  {/if}
</header>

<style>
  header { display: flex; align-items: center; gap: 8px; padding: 8px 16px 12px; }
  .orb { position: relative; width: 36px; height: 36px; display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .away { position: absolute; right: 1px; bottom: 1px; width: 9px; height: 9px; border-radius: 50%; background: var(--amber); box-shadow: 0 0 0 2px var(--canvas); }
  .titles { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  h1 { margin: 0; font: var(--pt-display); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
</style>
