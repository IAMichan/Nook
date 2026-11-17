<script lang="ts">
  // A soft breathing placeholder in the shape of the content to come (`NookSkeleton`, `NookSkeletonLines`): one block
  // of `width` × `height`, or with `lines` that many text lines, the last one shorter.
  let { width = "100%", height = 12, lines = 0, radius = "var(--radius-chip)" }: {
    width?: string; height?: number; lines?: number; radius?: string;
  } = $props();
</script>

{#if lines > 0}
  <div class="lines" aria-hidden="true">
    {#each Array.from({ length: lines }, (_, i) => i) as i (i)}
      <span class="bone" style:width={i === lines - 1 && lines > 1 ? "62%" : width} style:height="{height}px" style:border-radius={radius}></span>
    {/each}
  </div>
{:else}
  <span class="bone" style:width style:height="{height}px" style:border-radius={radius} aria-hidden="true"></span>
{/if}

<style>
  .lines { display: flex; flex-direction: column; gap: var(--space-6); }
  .bone { display: block; background: var(--smoke); animation: breathe 1.4s ease-in-out infinite alternate; }
  @keyframes breathe { from { opacity: 0.9; } to { opacity: 0.45; } }
  @media (prefers-reduced-motion: reduce) { .bone { animation: none; opacity: 0.7; } }
</style>
