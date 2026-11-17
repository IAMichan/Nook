<script lang="ts">
  // A short word on a soft chip beside a title (`NookTag`): "Draft", "Recommended", "Outdated". With a `tint` the word
  // wears that state color on a faint wash of it; without one it is a grey tag. `small` in a row, `regular` beside a
  // setting. A status (of a session, a connection) is a `StatusPill`, not a tag.
  let { text, tint, size = "small" }: { text: string; tint?: string; size?: "small" | "regular" } = $props();
</script>

<span class="tag {size}" class:tinted={!!tint} style:--tint={tint}>{text}</span>

<style>
  .tag { display: inline-flex; align-items: center; border-radius: var(--radius-chip); background: var(--smoke); color: var(--text2); white-space: nowrap; flex: none; }
  .tag.tinted { color: var(--tint); background: color-mix(in srgb, var(--tint) 14%, transparent); }
  .small { padding: 0 var(--space-6); font: 500 10.5px/16px var(--font); }
  .regular { padding: var(--space-2) var(--space-8); font: var(--text-label); }
</style>
