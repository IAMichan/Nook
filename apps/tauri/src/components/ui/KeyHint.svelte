<script lang="ts">
  // A key in a small chip (the Mac's `NookKeyHint`): shown beside a tab or row while Ctrl is held (`keyHold`).
  let { text }: { text: string } = $props();
</script>

<span class="key-hint" aria-hidden="true">{text}</span>

<style>
  .key-hint {
    display: inline-flex; align-items: center; height: 18px; padding: 0 var(--space-4); flex: none;
    font: var(--text-caption); color: var(--text3); background: var(--smoke); border-radius: var(--radius-chip);
    white-space: nowrap; pointer-events: none;
  }
</style>
