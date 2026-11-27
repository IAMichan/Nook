<script lang="ts">
  // Shown above the composer while this agent's child commands are paused under memory pressure
  // (`ResourceWaitStrip` in `apps/macos/UI/Panel/AgentWorkStrips.swift`, AG-76).
  import Ico from "../../../components/ui/Ico.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { agentGovernor } from "../../../lib/workspace/governor.svelte";

  let { runId }: { runId: string } = $props();

  const paused = $derived(agentGovernor.isPaused(runId));
  let releasing = $state(false);

  async function letGoOn() {
    if (releasing) return;
    releasing = true;
    try {
      await agentGovernor.letGoOn(runId);
    } finally {
      releasing = false;
    }
  }
</script>

{#if paused}
  <div class="wait-strip" role="status" aria-live="polite">
    <span class="ico"><Ico name="circle-pause" size={14} stroke={2} /></span>
    <div class="copy">
      <span class="title">{tr("De opdrachten van deze agent wachten even", "This agent's commands are waiting")}</span>
      <span class="detail">{tr("Je computer heeft weinig geheugen. Ze gaan verder zodra er ruimte is, hooguit over twee minuten.", "Your computer is short on memory. They go on as soon as there is room, in two minutes at most.")}</span>
    </div>
    <button type="button" class="go-on" disabled={releasing} onclick={letGoOn}>
      {tr("Laat doorgaan", "Let them go on")}
    </button>
  </div>
{/if}

<style>
  .wait-strip {
    display: flex;
    align-items: center;
    gap: var(--space-10);
    padding: var(--space-8) var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--surface);
    font: var(--text-detail);
    color: var(--text2);
    min-width: 0;
  }
  .ico {
    display: inline-flex;
    flex: none;
    color: var(--text2);
  }
  .copy {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    flex: 1;
    min-width: 0;
  }
  .title {
    color: var(--paper);
  }
  .detail {
    color: var(--text3);
  }
  .go-on {
    flex: none;
    margin: 0;
    padding: var(--space-4) var(--space-6);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    font: var(--text-detail);
    color: var(--iris);
    cursor: pointer;
    white-space: nowrap;
  }
  .go-on:hover:not(:disabled) {
    background: var(--smoke);
  }
  .go-on:disabled {
    opacity: 0.5;
    cursor: default;
  }
</style>
