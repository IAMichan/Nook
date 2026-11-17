<script lang="ts">
  // The line in a conversation above what came in since you last looked (`TimelineNewDivider`). Place it once, where
  // the conversation opened; the conversation itself still opens at its end.
  import { tr } from "../../lib/i18n.svelte";
</script>

<div class="divider" role="separator"><span>{tr("Nieuw sinds je laatste bezoek", "New since your last visit")}</span></div>

<style>
  .divider { display: flex; align-items: center; gap: var(--space-8); margin: var(--space-12) 0; color: var(--amber); font: var(--text-caption); }
  .divider::before, .divider::after { content: ""; flex: 1; height: 1px; background: color-mix(in srgb, var(--amber) 45%, transparent); }
</style>
