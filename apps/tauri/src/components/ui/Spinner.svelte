<script lang="ts">
  // The small turning ring of `ProgressView().controlSize(.small)`, in the text color around it.
  let { size = 12 }: { size?: number } = $props();
</script>

<span class="spinner" style:width="{size}px" style:height="{size}px" aria-hidden="true"></span>

<style>
  .spinner { display: inline-block; flex: none; border-radius: 50%; border: 1.5px solid color-mix(in srgb, currentColor 25%, transparent); border-top-color: currentColor; animation: turn 0.8s linear infinite; box-sizing: border-box; }
  @keyframes turn { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .spinner { animation-duration: 2.4s; } }
</style>
