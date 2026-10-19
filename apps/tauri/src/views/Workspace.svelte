<script lang="ts">
  // Werkruimte: terminals, browser en worktrees (stap 3).
  let { compact = false }: { compact?: boolean } = $props();
</script>

<div class="empty" class:compact>
  <p>De werkruimte is leeg.</p>
  <p class="faint">Start een sessie vanuit Agents; terminals en worktrees verschijnen hier.</p>
</div>

<style>
  .empty { padding: 24px; text-align: center; }
</style>
