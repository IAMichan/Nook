<script lang="ts">
  // "Runs on" under the composer (`RunsOnPicker` on the Mac): where the agent of a new session runs. This computer, one
  // of your machines over SSH (Settings › Devices › Machines) with a dot for whether it answers, "Automatic" once a
  // machine exists (`balance` in the core), and a way to add one.
  import Ico from "../../../components/ui/Ico.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import { api } from "../../../lib/api";
  import { tr } from "../../../lib/i18n.svelte";
  import type { RemoteMachine } from "../../../lib/workspace/machines";
  import { machineStatuses, type MachineStatus } from "../../../lib/workspace/machine-status.svelte";

  let { machines, chosen, automatic, onpick, onautomatic }: {
    machines: RemoteMachine[];
    chosen: RemoteMachine | null;
    automatic: boolean;
    onpick: (machine: RemoteMachine | null) => void;
    onautomatic: () => void;
  } = $props();

  function addMachine() {
    try { localStorage.setItem("settings.section", "machines"); } catch { /* opens on the last page instead */ }
    api.showMain("settings");
  }

  /** The machine's address, then how it answered. */
  function detail(m: RemoteMachine, s: MachineStatus): string {
    const address = m.port ? `${m.host}:${m.port}` : m.host;
    switch (s.kind) {
      case "checking": return `${address} · ${tr("verbinden…", "connecting…")}`;
      case "online": return `${address} · ${tr("verbonden", "connected")}`;
      case "offline": return `${address} · ${tr("niet bereikbaar", "not reachable")}`;
      default: return address;
    }
  }

  /** State colors keep their meaning: mint answers, amber is asking, coral does not answer. */
  const dotClass = (s: MachineStatus) => (s.kind === "online" ? "ok" : s.kind === "offline" ? "bad" : s.kind === "checking" ? "wait" : "");
</script>

<Dropdown width={300} below label={tr("Draait op", "Runs on")} onopen={() => machineStatuses.refresh(machines)}>
  {#snippet trigger({ toggle, open })}
    <button class="pill" onclick={toggle} aria-expanded={open} title={tr("Waar de agent draait", "Where the agent runs")}>
      <Ico name={chosen ? "server" : automatic ? "scale" : "laptop"} size={15} />
      {#if chosen}
        {@const cls = dotClass(machineStatuses.status(chosen.id))}
        {#if cls}<span class="dot {cls}" aria-hidden="true"></span>{/if}
      {/if}
      <span>{chosen ? chosen.name : automatic ? tr("Automatisch", "Automatic") : tr("Deze computer", "This computer")}</span><Ico name="chevron-down" size={10} stroke={2.5} />
    </button>
  {/snippet}
  {#snippet children({ close })}
    <div class="dd-header">{tr("Draait op", "Runs on")}</div>
    {#if machines.length}
      <DropdownRow symbol="scale" title={tr("Automatisch", "Automatic")} detail={tr("Nook kiest deze computer of een machine waar dit project ook staat.", "Nook picks this computer or a machine this project is shared with.")}
        chosen={automatic && !chosen} onclick={() => { close(); onautomatic(); }} />
    {/if}
    <DropdownRow symbol="laptop" title={tr("Deze computer", "This computer")} detail={tr("In een map of worktree hier.", "In a folder or worktree here.")}
      chosen={!chosen && !automatic} onclick={() => { close(); onpick(null); }} />
    {#each machines as m (m.id)}
      <DropdownRow symbol="server" title={m.name} detail={detail(m, machineStatuses.status(m.id))}
        chosen={chosen?.id === m.id} onclick={() => { close(); onpick(m); }} />
    {/each}
    <DropdownRow symbol="plus" title={tr("Machine toevoegen…", "Add a machine…")} detail={machines.length ? undefined : tr("Een andere computer via SSH", "Another computer over SSH")}
      onclick={() => { close(); addMachine(); }} />
  {/snippet}
</Dropdown>

<style>
  .pill { display: inline-flex; align-items: center; gap: var(--space-6); height: 28px; max-width: 200px; background: none; border: none; padding: 0 var(--space-8); font: var(--text-control); color: var(--text2); border-radius: var(--radius-control); white-space: nowrap; }
  .pill > span:not(.dot) { overflow: hidden; text-overflow: ellipsis; }
  .pill > :global(svg:last-child:not(:first-child)) { opacity: 0.6; }
  .pill:hover { background: var(--smoke); color: var(--paper); }
  .dot { width: 6px; height: 6px; border-radius: 999px; flex: none; }
  .dot.ok { background: var(--mint); }
  .dot.wait { background: var(--amber); }
  .dot.bad { background: var(--coral); }
</style>
