<script lang="ts">
  // Quiet mint "In use" check on the row of the active model, file, or option (the Mac's `InUseLabel` in
  // `SettingsBlocks.swift`), standing in the slot where other rows show their Use button.
  import Ico from "../../components/ui/Ico.svelte";
  import { tr } from "../../lib/i18n.svelte";

  let { label }: { label?: string } = $props();
</script>

<span class="in-use">
  <Ico name="circle-check" size={14} stroke={1.8} />
  <span>{label ?? tr("In gebruik", "In use")}</span>
</span>

<style>
  .in-use {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    flex: none;
    font: var(--text-label);
    color: var(--mint);
    white-space: nowrap;
  }
</style>
