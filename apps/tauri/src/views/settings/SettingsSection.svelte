<script lang="ts">
  // One grouped section of a Settings page, mirroring Mac's `SettingsFormSection` and `SettingsSectionTitle`
  // (`SettingsFormStyle.swift`): heading, optional always-visible explanation, optional header action, bordered
  // surface card with hairlines between rows (or bare without a card when `bare` is true), and optional footer.
  import type { Snippet } from "svelte";

  let {
    title,
    info = "",
    bare = false,
    action,
    children,
    footer,
  }: {
    title?: string;
    info?: string;
    bare?: boolean;
    action?: Snippet;
    children: Snippet;
    footer?: Snippet;
  } = $props();
</script>

{#if title}
  {#if action}
    <div class="section-head">
      <h3>{title}</h3>
      {@render action()}
    </div>
  {:else}
    <h3>{title}</h3>
  {/if}
  {#if info}<p class="section-info">{info}</p>{/if}
{/if}

{#if bare}
  <div class="bare-section">
    {@render children()}
  </div>
{:else}
  <div class="group">
    {@render children()}
  </div>
{/if}

{#if footer}
  <div class="section-footer">
    {@render footer()}
  </div>
{/if}

<style>
  .bare-section {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    margin-top: var(--space-8);
  }
  .section-footer {
    margin-top: var(--space-8);
    padding: 0 var(--space-2);
  }
</style>
