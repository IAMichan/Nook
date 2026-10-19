<script lang="ts" module>
  // Eén keer per domein ophalen, voor alle iconen samen.
  const cache = new Map<string, Promise<string | null>>();
</script>

<script lang="ts">
  // Het icoon van een dienst, van zijn eigen website (zoals op de Mac). Zonder icoon: de eerste letter in een tegel.
  import { connectorsApi } from "../../lib/connectors";

  let { domain, title, size = 30 }: { domain?: string | null; title: string; size?: number } = $props();
  let src = $state<string | null>(null);

  $effect(() => {
    src = null;
    const d = domain?.trim();
    if (!d) return;
    if (!cache.has(d)) cache.set(d, connectorsApi.serviceIcon(d).catch(() => null));
    let live = true;
    cache.get(d)!.then((s) => live && (src = s));
    return () => {
      live = false;
    };
  });

  const letter = $derived((title.trim()[0] ?? "?").toUpperCase());
  const hue = $derived([...title].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7));
</script>

<span class="tile" style="width:{size}px;height:{size}px;border-radius:{Math.round(size / 4)}px">
  {#if src}
    <img {src} alt="" width={Math.round(size * 0.72)} height={Math.round(size * 0.72)} onerror={() => (src = null)} />
  {:else}
    <span class="letter" style="background:hsl({hue} 45% 30%);font-size:{Math.round(size * 0.45)}px">{letter}</span>
  {/if}
</span>

<style>
  .tile { display: inline-grid; place-items: center; background: var(--paper); flex: none; overflow: hidden; }
  .letter { width: 100%; height: 100%; display: grid; place-items: center; color: var(--paper); font-weight: 600; }
  img { object-fit: contain; }
</style>
