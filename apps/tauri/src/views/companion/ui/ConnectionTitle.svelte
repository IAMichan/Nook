<script lang="ts">
  // Under a tab's title (`ConnectionTitle`): "{Mac} · live", or "Looking for {Mac}…" once it has been away a moment.
  import { tr } from "../../../lib/i18n.svelte";
  import type { ClientView } from "../../../lib/companion";
  let { view }: { view: ClientView } = $props();
  const mac = $derived(view.macName || tr("je Mac", "your Mac"));
  let away = $state(false);
  $effect(() => {
    if (view.phase !== "offline") return void (away = false);
    const timer = setTimeout(() => (away = true), 800);
    return () => clearTimeout(timer);
  });
</script>

{#if view.phase === "connected"}
  <span class="line"><span class="dot" style:background="var(--mint)"></span>{tr("{mac} · live", "{mac} · live", { mac })}</span>
{:else if away}
  <span class="line"><span class="dot" style:background="var(--amber)"></span>{tr("Zoeken naar {mac}…", "Looking for {mac}…", { mac })}</span>
{/if}

<style>
  .line { display: flex; align-items: center; gap: 6px; font: var(--pt-detail); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; animation: in var(--reveal); }
  .dot { width: 6px; height: 6px; border-radius: 50%; flex: none; }
  @keyframes in { from { opacity: 0; } }
</style>
