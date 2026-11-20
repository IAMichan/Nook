<script lang="ts">
  // Usage as a modal over the window (the Mac's `UsageModal` with `UsageLimitsModal`): a dimmed backdrop, a sheet of at
  // most 720 wide with "Usage", the Cost / Tokens / Limits switch, a filter menu (agent and period), refresh and close;
  // under it the chosen part. A click on the backdrop or Escape closes it.
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import type { RunProvider, UsageRange } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Dropdown from "../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../components/ui/DropdownRow.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import UsagePage from "../workspace/UsagePage.svelte";

  let { onclose }: { onclose: () => void } = $props();

  type Tab = "cost" | "tokens" | "limits";
  const TAB_KEY = "nook.usage.tab";
  let tab = $state<Tab>(((): Tab => { try { const t = localStorage.getItem(TAB_KEY); return t === "cost" || t === "tokens" ? t : "limits"; } catch { return "limits"; } })());
  let range = $state<UsageRange>((localStorage.getItem("ws.usage.range") as UsageRange) || "week");
  let provider = $state<RunProvider | "">("");
  let refreshing = $state(false);
  // A new key reads the report again.
  let generation = $state(0);

  function choose(next: Tab) {
    tab = next;
    try { localStorage.setItem(TAB_KEY, next); } catch { /* remembered while the window is open */ }
  }

  async function refresh() {
    refreshing = true;
    try {
      await Promise.all([agents.refresh(), agents.loadHistory(true), workspace.refresh()]);
      generation++;
    } finally {
      refreshing = false;
    }
  }

  const tabs = $derived<[Tab, string][]>([["cost", tr("Kosten", "Cost")], ["tokens", tr("Tokens", "Tokens")], ["limits", tr("Limieten", "Limits")]]);
  const ranges = $derived<[UsageRange, string][]>([["today", tr("Vandaag", "Today")], ["week", tr("7 dagen", "7 days")], ["month", tr("30 dagen", "30 days")], ["all", tr("Alles", "All")]]);
  const filtered = $derived(provider !== "" || range !== "week");

  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") { e.preventDefault(); onclose(); }
  }
</script>

<svelte:window onkeydown={keys} />

<div class="backdrop" role="presentation" onclick={onclose}>
  <div class="sheet" role="dialog" aria-modal="true" aria-label={tr("Gebruik", "Usage")} tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
    <header>
      <h2>{tr("Gebruik", "Usage")}</h2>
      <span class="spacer"></span>
      <div class="segments" role="tablist">
        {#each tabs as [t, label] (t)}<button role="tab" aria-selected={tab === t} class:on={tab === t} onclick={() => choose(t)}>{label}</button>{/each}
      </div>
      <Dropdown width={240} below align="right" label={tr("Filter", "Filter")}>
        {#snippet trigger({ toggle, open })}
          <button class="icon" class:on={open || filtered} onclick={toggle} aria-expanded={open} disabled={tab === "limits"}
            title={tr("Filter", "Filter")} aria-label={tr("Filter", "Filter")}><Ico name="list-filter" size={16} /></button>
        {/snippet}
        {#snippet children()}
          <div class="dd-header">{tr("Agent", "Agent")}</div>
          <DropdownRow title={tr("Alle agents", "All agents")} chosen={provider === ""} trailing={provider === "" ? "✓" : undefined} onclick={() => (provider = "")} />
          {#each workspace.providers.filter((p) => p.supported) as p (p.provider)}
            <DropdownRow brand={p.name} title={p.name} chosen={provider === p.provider} trailing={provider === p.provider ? "✓" : undefined} onclick={() => (provider = p.provider)} />
          {/each}
          <div class="dd-header">{tr("Periode", "Period")}</div>
          {#each ranges as [r, label] (r)}
            <DropdownRow title={label} chosen={range === r} trailing={range === r ? "✓" : undefined} onclick={() => (range = r)} />
          {/each}
        {/snippet}
      </Dropdown>
      <button class="icon" disabled={refreshing} onclick={refresh} title={tr("Vernieuwen", "Refresh")} aria-label={tr("Vernieuwen", "Refresh")}><span class:spin={refreshing}><Ico name="refresh-cw" size={15} /></span></button>
      <button class="icon" onclick={onclose} title={tr("Sluit", "Close")} aria-label={tr("Sluit", "Close")}><Ico name="x" size={16} /></button>
    </header>
    <div class="body">
      {#key `${tab}:${generation}`}
        <UsagePage part={tab} controls={false} bind:range bind:provider />
      {/key}
    </div>
  </div>
</div>

<style>
  .backdrop { position: fixed; inset: 0; z-index: 80; display: grid; place-items: center; padding: var(--space-24); background: color-mix(in srgb, var(--canvas) 55%, transparent); }
  .sheet {
    display: flex; flex-direction: column; width: min(720px, 100%); height: min(560px, 100%); min-height: 0;
    background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); overflow: hidden;
  }
  header { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-12) var(--space-24); border-bottom: 1px solid var(--line); }
  h2 { margin: 0; font: var(--text-heading); color: var(--paper); }
  .spacer { flex: 1; }
  .segments { display: inline-flex; gap: var(--space-2); padding: var(--space-2); margin-right: var(--space-8); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--graphite); }
  .segments button { height: 26px; margin: 0; padding: 0 var(--space-12); border: 0; border-radius: var(--radius-chip); background: transparent; font: var(--text-control); font-weight: 400; color: var(--text2); }
  .segments button:hover { color: var(--paper); background: transparent; }
  .segments button.on { background: var(--smoke); color: var(--paper); font-weight: 600; }
  .icon { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; margin: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .icon:hover:not(:disabled), .icon.on { background: var(--smoke); color: var(--paper); }
  .spin { display: inline-flex; animation: turn 0.9s linear infinite; }
  @keyframes turn { to { transform: rotate(360deg); } }
  .body { flex: 1; min-height: 0; overflow: hidden; padding: var(--space-16) var(--space-24); }
</style>
