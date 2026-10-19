<script lang="ts">
  // Een toestemmingsvraag (`ApprovalView` op de Mac): het hele commando of de hele wijziging, het risico, en
  // Toestaan, Altijd, Weigeren en In terminal. Wat je toestaat is wat je ziet: niets wordt ingekort.
  import type { AgentApproval } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import DiffView from "./DiffView.svelte";

  let { approval, others = 0, compact = false }: { approval: AgentApproval; others?: number; compact?: boolean } = $props();
  let busy = $state(false);

  async function decide(d: "allow" | "always" | "deny" | "terminal") {
    busy = true;
    await agents.decide(approval, d);
    busy = false;
  }
</script>

<div class="approval" class:danger={approval.danger} class:compact>
  <div class="context faint">
    <span class="dot waiting"></span>
    {approval.agentName} · {approval.project}{#if others > 0} · nog {others} wachtend{/if}
  </div>
  <div class="title">{approval.title}</div>
  {#if approval.diff.length}
    <div class="command small">{approval.command}</div>
    <DiffView lines={approval.diff} max={compact ? 150 : 260} />
  {:else}
    <pre class="command">{approval.command}</pre>
  {/if}
  {#if approval.note}<div class="note" class:warn={approval.danger}>{approval.note}</div>{/if}
  <div class="buttons">
    <button class="ghost" disabled={busy} onclick={() => decide("deny")}>Weigeren</button>
    <span class="spacer"></span>
    {#if approval.canTerminal}<button disabled={busy} onclick={() => decide("terminal")}>In terminal</button>{/if}
    {#if approval.canAlways}<button disabled={busy} onclick={() => decide("always")}>Altijd</button>{/if}
    <button class="primary" disabled={busy} onclick={() => decide("allow")}>Toestaan</button>
  </div>
</div>

<style>
  .approval { background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 12px 14px; display: flex; flex-direction: column; gap: 8px; }
  .approval.danger { border-color: color-mix(in srgb, var(--coral) 55%, var(--line2)); }
  .context { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .title { font-weight: 600; font-size: 14px; }
  .command {
    margin: 0;
    font-family: var(--mono);
    font-size: 12px;
    background: var(--field);
    border: 1px solid var(--line2);
    border-radius: 10px;
    padding: 8px 10px;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 180px;
    overflow-y: auto;
    user-select: text;
  }
  .command.small { background: none; border: none; padding: 0; color: var(--text2); }
  .compact .command { max-height: 110px; }
  .note { font-size: 12px; color: var(--text2); }
  .note.warn { color: var(--coral); }
  .buttons { display: flex; gap: 6px; align-items: center; }
  .spacer { flex: 1; }
</style>
