<script lang="ts">
  // Under a tab's title (`ConnectionTitle`): "{Mac} · live", or "Looking for {Mac}…" once it has been away a moment.
  // With several computers paired it is the quick switcher: a tap opens the list of every paired computer
  // (`oncomputers`, the menu `Companion.svelte` shows), as on the iPhone.
  import { tr } from "../../../lib/i18n.svelte";
  import { fallbackComputerName, type ClientView } from "../../../lib/companion";
  import Ico from "../../../components/ui/Ico.svelte";
  let { view, oncomputers }: { view: ClientView; oncomputers?: (r: DOMRect) => void } = $props();
  const platform = $derived(view.macs?.find((m) => m.active)?.platform);
  const mac = $derived(view.macName || fallbackComputerName(platform));
  const switchable = $derived(!!oncomputers && (view.macs?.length ?? 0) > 1);
  let away = $state(false);
  $effect(() => {
    if (view.phase !== "offline") return void (away = false);
    const timer = setTimeout(() => (away = true), 800);
    return () => clearTimeout(timer);
  });
</script>

{#snippet status()}
  {#if view.phase === "connected"}
    <span class="line"><span class="dot" style:background="var(--mint)"></span><span class="text">{tr("{mac} · live", "{mac} · live", { mac })}</span>{#if switchable}<Ico name="chevron-down" size={12} />{/if}</span>
  {:else if away}
    <span class="line"><span class="dot" style:background="var(--amber)"></span><span class="text">{tr("Zoeken naar {mac}…", "Looking for {mac}…", { mac })}</span>{#if switchable}<Ico name="chevron-down" size={12} />{/if}</span>
  {/if}
{/snippet}

{#if switchable}
  <button class="switch press" aria-haspopup="menu" aria-label={tr("Wissel naar een andere computer", "Switch to another computer")}
    onclick={(e) => oncomputers?.((e.currentTarget as HTMLElement).getBoundingClientRect())}>{@render status()}</button>
{:else}
  {@render status()}
{/if}

<style>
  .switch { display: flex; min-width: 0; max-width: 100%; padding: 0; text-align: left; color: inherit; }
  .line { display: flex; align-items: center; gap: 6px; min-width: 0; font: var(--pt-detail); color: var(--text3); white-space: nowrap; animation: in var(--reveal); }
  .text { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .dot { width: 6px; height: 6px; border-radius: 50%; flex: none; }
  @keyframes in { from { opacity: 0; } }
</style>
