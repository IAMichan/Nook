<script lang="ts">
  // Een toestemmingsvraag (`ApprovalView` op de Mac): het hele commando of de hele wijziging, het risico, en
  // Toestaan, Altijd, Weigeren en In terminal. Wat je toestaat is wat je ziet: niets wordt ingekort.
  import type { AgentApproval } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import DiffView from "./DiffView.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  let { approval, others = 0, compact = false }: { approval: AgentApproval; others?: number; compact?: boolean } = $props();
  let busy = $state(false);
  let writingReason = $state(false);
  let reason = $state("");

  async function decide(d: "allow" | "always" | "deny" | "terminal") {
    busy = true;
    await agents.decide(approval, d);
    busy = false;
  }

  /// Deny (`ApprovalView.deny` on the Mac): with the typed reason when there is one.
  async function deny() {
    const text = reason.trim();
    if (writingReason && text) {
      busy = true;
      reason = "";
      writingReason = false;
      await agents.denyWithReason(approval, text);
      busy = false;
    } else {
      await decide("deny");
    }
  }

  // A request through the bridge has no agent behind it to tell why.
  const canReason = $derived(!approval.id.startsWith("bridge-"));

  function focusOnMount(node: HTMLTextAreaElement) {
    node.focus();
  }
</script>

<div class="approval" class:danger={approval.danger} class:compact>
  <div class="context faint">
    <span class="dot waiting"></span>
    {approval.agentName} · {approval.project}{#if others > 0} · {tr("nog {n} wachtend", "{n} more waiting", { n: others })}{/if}
  </div>
  <div class="title">{approval.title}</div>
  {#if approval.diff.length}
    <div class="command small">{approval.command}</div>
    <DiffView lines={approval.diff} max={compact ? 150 : 260} />
  {:else}
    <pre class="command">{approval.command}</pre>
  {/if}
  {#if approval.note}<div class="note" class:warn={approval.danger}>{approval.note}</div>{/if}
  {#if writingReason}
    <!-- Where the reason for a denial is typed: Return denies with it, Escape closes it again. -->
    <div class="reason">
      <Ico name="message-square-text" size={15} />
      <textarea use:focusOnMount rows="1" bind:value={reason} placeholder={tr("Waarom niet, of wat in plaats daarvan", "Why not, or what to do instead")}
        aria-label={tr("Weigeren met reden", "Deny with reason")}
        onkeydown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); deny(); } else if (e.key === "Escape") { e.stopPropagation(); writingReason = false; reason = ""; } }}></textarea>
    </div>
  {/if}
  <div class="buttons">
    <button class="ghost" disabled={busy} onclick={deny}>{tr("Weigeren", "Deny")}</button>
    {#if canReason && !writingReason}<button class="ghost" disabled={busy} onclick={() => (writingReason = true)}>{tr("Weigeren met reden", "Deny with reason")}</button>{/if}
    <span class="spacer"></span>
    {#if approval.canTerminal}<button disabled={busy} onclick={() => decide("terminal")}>{tr("In terminal", "In terminal")}</button>{/if}
    {#if approval.canAlways}<button disabled={busy} onclick={() => decide("always")}>{tr("Altijd", "Always")}</button>{/if}
    <button class="primary" disabled={busy} onclick={() => decide("allow")}>{tr("Toestaan", "Allow")}</button>
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
  .reason { display: flex; align-items: flex-start; gap: var(--space-8); color: var(--text3); }
  .reason > :global(svg) { margin-top: var(--space-8); }
  .reason textarea { flex: 1; min-height: 30px; padding: var(--space-6) calc(var(--space-8) + var(--space-2)); resize: none; field-sizing: content; max-height: 96px; border: 1px solid var(--field-stroke); border-radius: var(--radius-control); background: var(--field); font: var(--text-body); color: var(--paper); }
  .buttons { display: flex; gap: 6px; align-items: center; }
  .spacer { flex: 1; }
</style>
