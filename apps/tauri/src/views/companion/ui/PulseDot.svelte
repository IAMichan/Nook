<script lang="ts">
  // A dot with a ring that grows and fades every 1.2 seconds (`PulseDot`): something is working right now.
  let { size = 6, color = "var(--blue)" }: { size?: number; color?: string } = $props();
</script>

<span class="pulse" style:width="{size * 2}px" style:height="{size * 2}px" aria-hidden="true">
  <span class="ring" style:width="{size}px" style:height="{size}px" style:background={color}></span>
  <span class="dot" style:width="{size}px" style:height="{size}px" style:background={color}></span>
</span>

<style>
  .pulse { position: relative; display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .dot, .ring { position: absolute; border-radius: 50%; }
  .ring { animation: ring 1.2s ease-out infinite; }
  @keyframes ring { from { transform: scale(1); opacity: 0.45; } to { transform: scale(1.9); opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .ring { display: none; } }
</style>
