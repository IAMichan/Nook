<script lang="ts">
  // A switch on a Settings row, mirroring Mac's `SettingToggle` (`SettingsBlocks.swift`):
  // the name and optional smaller explanation on the left, the compact switch on the right.
  let {
    title,
    detail = "",
    checked = $bindable(false),
    disabled = false,
    onchange,
  }: {
    title: string;
    detail?: string;
    checked?: boolean;
    disabled?: boolean;
    onchange?: (checked: boolean) => void;
  } = $props();

  function handleChange(e: Event) {
    const next = (e.currentTarget as HTMLInputElement).checked;
    checked = next;
    onchange?.(next);
  }
</script>

<label class="row setting-toggle" class:disabled>
  <span class="row-copy">
    <span class="row-title">{title}</span>
    {#if detail}<small class="row-detail">{detail}</small>{/if}
  </span>
  <input type="checkbox" role="switch" {checked} {disabled} onchange={handleChange} />
</label>

<style>
  .row-copy {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .row-title {
    color: var(--paper);
  }
  .row-detail {
    display: block;
    font: var(--text-detail);
    line-height: 1.3;
    color: var(--text2);
  }
  .setting-toggle.disabled .row-title {
    color: var(--text2);
  }
</style>
