<script lang="ts">
  // An empty page (`WSEmptyState`, `NookEmptyState`): an icon, a title, a line, and maybe one action.
  import Ico from "./Ico.svelte";
  let { icon, title, text, action, onaction }: { icon: string; title: string; text: string; action?: string; onaction?: () => void } = $props();
</script>

<div class="empty">
  <span class="icon"><Ico name={icon} size={28} stroke={1.8} /></span>
  <strong>{title}</strong>
  <p>{text}</p>
  {#if action && onaction}<button class="primary press" onclick={onaction}>{action}</button>{/if}
</div>

<style>
  .empty { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 40px 24px; text-align: center; }
  .icon { color: var(--text3); margin-bottom: 4px; }
  strong { font: var(--pt-title, var(--text-title)); color: var(--paper); }
  p { margin: 0; font: var(--pt-body, var(--text-body)); color: var(--text2); max-width: 320px; }
  .primary { margin-top: var(--space-8); }
  :global(.phone) .primary { height: 44px; padding: 0 20px; border-radius: 999px; background: var(--iris); color: var(--on-iris); font: 600 16px var(--font); }
</style>
