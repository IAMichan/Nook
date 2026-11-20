<script lang="ts">
  // A row that leads to another Settings page (the Mac's `SettingsLinkRow`): a line icon, what you find there, an
  // optional mark that something there needs you, and a chevron. The whole row is the button.
  import { emit } from "@tauri-apps/api/event";
  import Ico from "../../components/ui/Ico.svelte";
  import type { SettingsSectionId } from "../../lib/settings-pages";
  let { icon, title, to, warn = false }: { icon: string; title: string; to: SettingsSectionId; warn?: boolean } = $props();
</script>

<button type="button" class="row link-row" onclick={() => emit("navigate", `settings:${to}`).catch(() => {})}>
  <span class="mark"><Ico name={icon} size={14} /></span>
  <span class="title">{title}</span>
  {#if warn}<span class="warn"><Ico name="circle-alert" size={14} /></span>{/if}
  <Ico name="chevron-right" size={12} />
</button>

<style>
  .link-row { width: 100%; justify-content: flex-start; gap: var(--space-12); border-radius: 0; background: none; text-align: left; color: var(--text2); }
  .link-row:hover:not(:disabled) { background: none; color: var(--paper); }
  .mark { display: grid; place-items: center; width: 24px; height: 24px; border-radius: var(--radius-chip); background: var(--settings-fill); color: var(--text-strong); }
  .title { flex: 1; color: var(--paper); }
  .warn { color: var(--amber); display: inline-flex; }
</style>
