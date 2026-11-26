<script lang="ts">
  // Shared chrome for every setup or connection sheet Settings opens, mirroring Mac's `SetupSheet`
  // (`SettingsStyle.swift`): icon, title, subtitle and optional `HealthPill` on top; scrollable body in the middle;
  // footer bar at the bottom (Done alone when steps do the work, Cancel + primary action on the right for a form,
  // disconnect/remove on the left). Escape closes the sheet via `Sheet`. When `embedded` is true, renders only the
  // body content without modal chrome, header, or footer (for inline expansion inside a `ConnectionRow`).
  import type { Snippet } from "svelte";
  import type { Health } from "../../lib/connectors";
  import HealthPill from "../../views/connectors/HealthPill.svelte";
  import Sheet from "./Sheet.svelte";

  let {
    title,
    subtitle,
    status,
    statusText,
    width = "default",
    embedded = false,
    onclose,
    icon,
    children,
    footer,
  }: {
    title: string;
    subtitle: string;
    status?: Health;
    statusText?: string;
    width?: "default" | "wide";
    embedded?: boolean;
    onclose: () => void;
    icon?: Snippet;
    children: Snippet;
    footer?: Snippet;
  } = $props();
</script>

{#if embedded}
  <div class="embedded">{@render children()}</div>
{:else}
  <Sheet {onclose} label={title} wide={width === "wide"}>
    <header class="setup-head">
      {#if icon}<div class="setup-icon">{@render icon()}</div>{/if}
      <div class="setup-head-text">
        <h3 class="setup-title">{title}</h3>
        <p class="setup-subtitle">{subtitle}</p>
      </div>
      {#if status}
        <div class="setup-status">
          <HealthPill health={status} text={statusText} />
        </div>
      {/if}
    </header>

    <div class="setup-body">
      {@render children()}
    </div>

    {#if footer}
      <footer class="setup-foot">
        {@render footer()}
      </footer>
    {/if}
  </Sheet>
{/if}

<style>
  .embedded {
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
    width: 100%;
  }
  .setup-head {
    display: flex;
    align-items: center;
    gap: var(--space-16);
    padding: var(--space-24);
    border-bottom: 1px solid var(--separator);
    flex: none;
  }
  .setup-icon {
    flex: none;
    display: grid;
    place-items: center;
  }
  .setup-head-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .setup-title {
    margin: 0;
    font: var(--text-heading);
    color: var(--paper);
  }
  .setup-subtitle {
    margin: 0;
    font: var(--text-detail);
    line-height: 1.35;
    color: var(--text2);
  }
  .setup-status {
    flex: none;
    align-self: center;
  }
  .setup-body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: var(--space-24);
    display: flex;
    flex-direction: column;
    gap: var(--space-20);
  }
  .setup-foot {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    flex-wrap: wrap;
    padding: var(--space-16) var(--space-24);
    border-top: 1px solid var(--separator);
    flex: none;
  }
</style>
