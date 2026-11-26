<script lang="ts">
  // A short line inside or below a Settings card (hint, success, warning, or error), mirroring Mac's `SettingNote`
  // (`SettingsBlocks.swift`). Warnings, errors, and successes carry a symbol so they communicate by more than color.
  import type { Snippet } from "svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { settingNoteMeta, type SettingNoteTone } from "./setting-note";

  let {
    text,
    tone = "info",
    children,
  }: {
    text?: string;
    tone?: SettingNoteTone;
    children?: Snippet;
  } = $props();

  const meta = $derived(settingNoteMeta(tone));
</script>

<p class="setting-note {meta.toneClass}">
  {#if meta.icon}
    <span class="note-icon" aria-hidden="true"><Ico name={meta.icon} size={13} stroke={2} /></span>
  {/if}
  <span class="note-text">
    {#if children}{@render children()}{:else}{text}{/if}
  </span>
</p>

<style>
  .setting-note {
    margin: 0;
    display: flex;
    align-items: flex-start;
    gap: var(--space-6);
    font: var(--text-detail);
    line-height: 1.35;
    color: var(--text2);
  }
  .setting-note.success {
    color: var(--mint);
  }
  .setting-note.warning {
    color: var(--amber);
  }
  .setting-note.error {
    color: var(--coral);
  }
  .note-icon {
    flex: none;
    display: inline-flex;
    align-items: center;
    padding-top: var(--space-2);
  }
  .note-text {
    flex: 1;
    min-width: 0;
  }
</style>
