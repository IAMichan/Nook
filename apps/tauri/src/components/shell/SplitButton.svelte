<script lang="ts">
  // The split view button in the sidebar's head (the Mac's `PanelSplitButton`): lit while a second tab shows, and a
  // short list to pick which one (or none), then the same tabs to open in a window of their own.
  import { tr } from "../../lib/i18n.svelte";
  import { SPLIT_CHOICES, TAB_MARKS, splitSide, type SplitTab } from "../../lib/panel-split";
  import type { Route } from "../../lib/shell-routes";
  import { split } from "../../lib/tab-windows.svelte";
  import { tip } from "../ui/tip";
  import { toast } from "../../lib/toast.svelte";
  import Dropdown from "../ui/Dropdown.svelte";
  import DropdownRow from "../ui/DropdownRow.svelte";
  import Ico from "../ui/Ico.svelte";

  let { current, titleOf }: { current: Route; titleOf: (r: Route) => string } = $props();
  let open = $state(false);
  const on = $derived(splitSide(split.stored, current) !== null);

  async function toWindow(tab: SplitTab, close: () => void) {
    close();
    try { await split.openWindow(tab); }
    catch (e) { toast.error(tr("Kon het venster niet openen", "Could not open the window"), e); }
  }
</script>

<Dropdown bind:open below width={220} label={tr("Gesplitst scherm", "Split view")}>
  {#snippet trigger({ toggle })}
    <button class="ghost icon-button split-button" class:on aria-haspopup="dialog" aria-expanded={open} use:tip={tr("Gesplitst scherm", "Split view")} onclick={toggle}>
      <Ico name="columns-2" size={15} />
    </button>
  {/snippet}
  {#snippet children({ close })}
    <div class="dd-header">{tr("Ernaast tonen", "Show beside")}</div>
    {#each SPLIT_CHOICES as tab (tab)}
      <DropdownRow symbol={TAB_MARKS[tab]} title={titleOf(tab)} chosen={split.stored === tab}
        disabledReason={tab === current ? tr("Deze tab heb je al open", "This tab is already open") : undefined}
        onclick={() => { split.choose(tab); close(); }} />
    {/each}
    <div class="dd-divider"></div>
    <DropdownRow symbol="square" title={tr("Uit", "Off")} chosen={!split.stored} onclick={() => { split.choose(null); close(); }} />
    <div class="dd-divider"></div>
    <div class="dd-header">{tr("In een eigen venster", "In its own window")}</div>
    {#each SPLIT_CHOICES as tab (tab)}
      <DropdownRow symbol={TAB_MARKS[tab]} title={titleOf(tab)} chosen={split.windows.includes(tab)} onclick={() => toWindow(tab, close)} />
    {/each}
  {/snippet}
</Dropdown>

<style>
  .split-button { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .split-button:hover { background: var(--row-hover); color: var(--paper); }
  .split-button.on { background: var(--smoke); color: var(--paper); }
  .dd-divider { height: 1px; margin: var(--space-4) var(--space-4); background: var(--hairline); }
</style>
