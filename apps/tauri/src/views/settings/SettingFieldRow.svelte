<script lang="ts">
  // A labeled field or control on a Settings row, mirroring Mac's `SettingFieldRow` (`SettingsBlocks.swift`):
  // title + optional smaller explanation on the left, control aligned to `SettingsControl.fieldWidth` (220 px) on the
  // right; or `stacked` with the full-width field directly underneath the label for multiline inputs.
  import type { Snippet } from "svelte";

  let {
    title,
    detail = "",
    stacked = false,
    children,
  }: {
    title: string;
    detail?: string;
    stacked?: boolean;
    children: Snippet;
  } = $props();

  // The title names the field's own control for screen readers. A wrapping <label> would also forward clicks on the
  // title to a button in the slot, so the first select, input or textarea without its own name gets aria-labelledby.
  const titleId = $props.id();
  let slot: HTMLElement | undefined = $state();
  $effect(() => {
    const control = slot?.querySelector<HTMLElement>("select, input, textarea");
    if (control && !control.hasAttribute("aria-label") && !control.hasAttribute("aria-labelledby")) {
      control.setAttribute("aria-labelledby", titleId);
    }
  });
</script>

<div class="row setting-field-row" class:stacked>
  <span class="row-copy">
    <span class="row-title" id={titleId}>{title}</span>
    {#if detail}<small class="row-detail">{detail}</small>{/if}
  </span>
  <div class="field-slot" class:stacked bind:this={slot}>
    {@render children()}
  </div>
</div>

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
  .field-slot {
    flex: 0 1 220px;
    max-width: 100%;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-8);
  }
  .field-slot.stacked {
    flex: none;
    width: 100%;
    flex-direction: column;
    align-items: stretch;
    justify-content: flex-start;
  }
  .field-slot :global(input:not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="color"])),
  .field-slot :global(textarea) {
    width: 100%;
  }
</style>
