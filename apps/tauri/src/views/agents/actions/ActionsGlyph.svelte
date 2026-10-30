<script lang="ts">
  // The mark of the Actions page in the footer (`ActionsGlyph` on the Mac): a play triangle in a circle, the shape
  // GitHub uses for Actions, on the same 16-point grid and stroke as `PullGlyph` so the two footer buttons match.
  let { size = 14 }: { size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  <circle cx="8" cy="8" r="6.2" />
  <path d="M6.6 5.4v5.2L10.8 8z" />
</svg>
