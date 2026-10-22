<script lang="ts">
  import type { ViewModule } from "../lib/shell-routes";

  let { load, label, onretry = () => window.location.reload() }: {
    load: () => Promise<ViewModule>; label: string; onretry?: () => void;
  } = $props();
  const view = $derived(load());
</script>

{#await view}
  <div class="route-state" role="status" aria-live="polite">
    <strong>Loading {label}…</strong>
    <p>You can keep using navigation while this view loads.</p>
  </div>
{:then module}
  <module.default />
{:catch}
  <div class="route-state" role="alert">
    <strong>Could not load {label}</strong>
    <p>Check your connection, then reload Nook to try again.</p>
    <button onclick={onretry}>Reload Nook</button>
  </div>
{/await}

<style>
  .route-state { padding: 28px; color: var(--paper); }
  p { color: var(--text2); font-size: 13px; }
</style>
