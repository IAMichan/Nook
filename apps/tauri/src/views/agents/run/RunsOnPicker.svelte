<script lang="ts">
  // "Runs on" under the composer (`RunsOnPicker` on the Mac): where the agent of a new session runs. This computer, or
  // one of your machines over SSH (Settings › Devices › Machines), and a way to add one.
  import Ico from "../../../components/ui/Ico.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import { api } from "../../../lib/api";
  import { tr } from "../../../lib/i18n.svelte";
  import type { RemoteMachine } from "../../../lib/workspace/machines";

  let { machines, chosen, onpick }: { machines: RemoteMachine[]; chosen: RemoteMachine | null; onpick: (machine: RemoteMachine | null) => void } = $props();

  function addMachine() {
    try { localStorage.setItem("settings.section", "machines"); } catch { /* opens on the last page instead */ }
    api.showMain("settings");
  }
</script>

<Dropdown width={300} below label={tr("Draait op", "Runs on")}>
  {#snippet trigger({ toggle, open })}
    <button class="pill" onclick={toggle} aria-expanded={open} title={tr("Waar de agent draait", "Where the agent runs")}>
      <Ico name={chosen ? "server" : "laptop"} size={15} /><span>{chosen ? chosen.name : tr("Deze computer", "This computer")}</span><Ico name="chevron-down" size={10} stroke={2.5} />
    </button>
  {/snippet}
  {#snippet children({ close })}
    <div class="dd-header">{tr("Draait op", "Runs on")}</div>
    <DropdownRow symbol="laptop" title={tr("Deze computer", "This computer")} detail={tr("In een map of worktree hier.", "In a folder or worktree here.")}
      chosen={!chosen} onclick={() => { close(); onpick(null); }} />
    {#each machines as m (m.id)}
      <DropdownRow symbol="server" title={m.name} detail={m.port ? `${m.host}:${m.port}` : m.host}
        chosen={chosen?.id === m.id} onclick={() => { close(); onpick(m); }} />
    {/each}
    <DropdownRow symbol="plus" title={tr("Machine toevoegen…", "Add a machine…")} detail={machines.length ? undefined : tr("Een andere computer via SSH", "Another computer over SSH")}
      onclick={() => { close(); addMachine(); }} />
  {/snippet}
</Dropdown>

<style>
  .pill { display: inline-flex; align-items: center; gap: var(--space-6); height: 28px; max-width: 200px; background: none; border: none; padding: 0 var(--space-8); font: var(--text-control); color: var(--text2); border-radius: var(--radius-control); white-space: nowrap; }
  .pill > span { overflow: hidden; text-overflow: ellipsis; }
  .pill > :global(svg:last-child:not(:first-child)) { opacity: 0.6; }
  .pill:hover { background: var(--smoke); color: var(--paper); }
</style>
