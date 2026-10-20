<script lang="ts">
  // The pull request marks GitHub uses (`PullRequestStateGlyph` on the Mac), on a 16-point grid: open (a node, a line
  // and a branch bending back), draft (the branch dashed), merged (the branch joining in) and closed (a cross on top).
  let { glyph = "open", size = 14 }: { glyph?: "open" | "draft" | "merged" | "closed"; size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  <circle cx="4" cy="3.5" r="1.8" />
  <circle cx="4" cy="12.5" r="1.8" />
  <path d="M4 5.3v5.4" />
  {#if glyph === "merged"}
    <circle cx="12" cy="9" r="1.8" />
    <path d="M4 5.3c0 2.6 2.4 3.7 6.2 3.7" />
  {:else}
    <circle cx="12" cy="12.5" r="1.8" />
    {#if glyph === "closed"}
      <path d="M12 10.7V8.2M10.4 2.6l3.2 3.2M13.6 2.6l-3.2 3.2" />
    {:else}
      <path d="M12 10.7V6.5a2.5 2.5 0 0 0-2.5-2.5H7.2M8.7 2.5 7.2 4l1.5 1.5" stroke-dasharray={glyph === "draft" ? "1.6 1.6" : undefined} />
    {/if}
  {/if}
</svg>
