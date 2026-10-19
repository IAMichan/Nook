<script lang="ts">
  // Agents: sessies van Claude Code, Codex en andere coding-agents. Wordt gevuld door de agent-hub (stap 3).
  let { compact = false }: { compact?: boolean } = $props();
</script>

<div class="empty" class:compact>
  <p>Nog geen agents gekoppeld.</p>
  <p class="faint">Koppel Claude Code, Codex of een andere agent bij Instellingen › Agents.</p>
</div>

<style>
  .empty { padding: 24px; text-align: center; }
</style>
