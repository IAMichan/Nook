<script lang="ts">
  import type { ViewModule } from "../lib/shell-routes";
  import { tr } from "../lib/i18n.svelte";

  let { load, label, onretry = () => window.location.reload() }: {
    load: () => Promise<ViewModule>; label: string; onretry?: () => void;
  } = $props();
  const view = $derived(load());
</script>

{#await view}
  <div class="route-state" role="status" aria-live="polite">
    <strong>{tr("{label} laden…", "Loading {label}…", { label })}</strong>
    <p>{tr("Je kunt de navigatie blijven gebruiken terwijl dit scherm laadt.", "You can keep using navigation while this view loads.")}</p>
  </div>
{:then module}
  <module.default />
{:catch}
  <div class="route-state" role="alert">
    <strong>{tr("{label} kon niet laden", "Could not load {label}", { label })}</strong>
    <p>{tr("Controleer je verbinding en laad Nook opnieuw om het nog eens te proberen.", "Check your connection, then reload Nook to try again.")}</p>
    <button onclick={onretry}>{tr("Nook opnieuw laden", "Reload Nook")}</button>
  </div>
{/await}

<style>
  .route-state { padding: 28px; color: var(--paper); }
  p { color: var(--text2); font-size: 13px; }
</style>
