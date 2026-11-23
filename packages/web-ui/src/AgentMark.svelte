<script lang="ts" module>
  let next = 0;
</script>

<script lang="ts">
  // The mark of an agent, a model or this Mac, as the Mac draws it (`AgentLogo`, `BrandMark`): the brand's own mark
  // where there is one, Antigravity's arch, a laptop for this Mac's models, else the name's first letter in a tile
  // (`letter`) or nothing.
  import { brandPaths } from "./brandLogos";
  import { brandFill, brandFor } from "./brands";

  let { name, size = 16, local = false, letter = false }: { name: string; size?: number; local?: boolean; letter?: boolean } = $props();

  const id = `nook-mark-${next++}`;
  const antigravity = $derived(name.toLowerCase().includes("antigravity"));
  const brand = $derived(local || antigravity ? undefined : brandFor(name));
  const fill = $derived(brand ? brandFill(brand) : null);
</script>

{#if local}
  <svg class="mark laptop" width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
    <path d="M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z" />
    <path d="M20.054 15.987H3.946" />
  </svg>
{:else if brand}
  <svg class="mark" width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
    {#if Array.isArray(fill)}
      <defs>
        <linearGradient {id} x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stop-color={fill[0]} />
          <stop offset="1" stop-color={fill[1]} />
        </linearGradient>
      </defs>
    {/if}
    {#each brandPaths[brand] ?? [] as d}
      <path {d} fill-rule="evenodd" fill={Array.isArray(fill) ? `url(#${id})` : (fill ?? "currentColor")} />
    {/each}
  </svg>
{:else if antigravity}
  <svg class="mark tile" width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
    <defs>
      <linearGradient {id} x1="0" y1="1" x2="1" y2="0">
        <stop offset="0" stop-color="#4F8BF7" />
        <stop offset="0.5" stop-color="#EA4335" />
        <stop offset="1" stop-color="#FBBC04" />
      </linearGradient>
    </defs>
    <rect x="0.25" y="0.25" width="23.5" height="23.5" rx="6.7" fill="#171717" stroke="var(--nc-line, #3f3f46)" stroke-width="0.5" />
    <path d="M5.3 18.7 12 5.3l6.7 13.4M8.8 14.1h6.4" fill="none" stroke={`url(#${id})`} stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
{:else if letter}
  <span class="mark letter" style:width="{size}px" style:height="{size}px" style:font-size="{size * 0.52}px" aria-hidden="true">
    {name.slice(0, 1).toUpperCase()}
  </span>
{/if}

<style>
  .mark { flex-shrink: 0; display: block; }
  .laptop { fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  .letter {
    display: grid;
    place-items: center;
    border-radius: 28%;
    background: color-mix(in srgb, currentColor 20%, transparent);
    font-weight: 700;
    line-height: 1;
  }
</style>
