<script lang="ts">
  // Wat een agent van je wil, bovenaan de open balk: eerst toestemmingsvragen, dan meerkeuzevragen, dan het kaartje
  // "klaar / liep vast / wacht op je" met wat hij zei. Beantwoord je in de terminal, dan verdwijnt de kaart vanzelf.
  import { agentApi } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import ApprovalCard from "./ApprovalCard.svelte";
  import QuestionCard from "./QuestionCard.svelte";

  // `requests`: ook toestemmingsvragen en meerkeuzevragen tonen (niet als de tab Agents ze zelf al toont).
  let { onview, requests = true }: { onview: (sessionId: string) => void; requests?: boolean } = $props();

  const approval = $derived(requests ? agents.approvals[0] : undefined);
  const question = $derived(requests && !approval ? agents.questions[0] : undefined);
  const card = $derived(!approval && !question ? agents.attention : null);
  let terminalName = $state("terminal");

  $effect(() => {
    if (card?.host) agentApi.terminalName(card.host).then((n) => (terminalName = n));
    else terminalName = "terminal";
  });

  const stateText = $derived(card?.status === "done" ? "klaar" : card?.status === "failed" ? "liep vast" : "wacht op je");
  const fallback = $derived(
    card?.status === "done" ? "Klaar met je opdracht." : card?.status === "failed" ? "Er ging iets mis." : "Wacht op je antwoord in de terminal.",
  );

  async function openTerminal() {
    if (!card) return;
    try {
      await agentApi.activateTerminal(card.host);
      agents.attention = null;
    } catch {
      agents.error = `Ik vind de terminal van ${card.name} niet. Staat hij nog open?`;
    }
  }
</script>

{#if approval}
  <div class="alert"><ApprovalCard {approval} others={agents.approvals.length - 1} compact /></div>
{:else if question}
  {#key question.id}<div class="alert"><QuestionCard request={question} /></div>{/key}
{:else if card}
  <div class="alert">
    <div class="status" class:done={card.status === "done"} class:failed={card.status === "failed"}>
      <div class="context faint">
        <span class="dot {card.status === 'done' ? 'unread' : card.status === 'failed' ? 'error' : 'waiting'}"></span>
        {card.name} · {card.project} · {stateText}{#if card.linesAdded + card.linesRemoved > 0} · +{card.linesAdded} −{card.linesRemoved}{/if}
      </div>
      <div class="title">{card.summary || fallback}</div>
      <div class="buttons">
        <button class="ghost" onclick={() => (agents.attention = null)}>Sluit</button>
        <span class="spacer"></span>
        {#if card.host}<button onclick={openTerminal}>Open {terminalName}</button>{/if}
        <button class="primary" onclick={() => { onview(card.id); agents.attention = null; }}>Bekijk</button>
      </div>
    </div>
  </div>
{/if}
{#if agents.confirmation}
  <div class="toast">{agents.confirmation}</div>
{/if}

<style>
  .alert { padding: 4px 12px 8px; }
  .status { background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 12px 14px; display: flex; flex-direction: column; gap: 8px; }
  .status.done { border-color: color-mix(in srgb, var(--mint) 40%, var(--line2)); }
  .status.failed { border-color: color-mix(in srgb, var(--coral) 45%, var(--line2)); }
  .context { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .title { font-weight: 600; font-size: 14px; line-height: 1.35; }
  .buttons { display: flex; gap: 6px; }
  .spacer { flex: 1; }
  .toast { position: absolute; bottom: 14px; left: 50%; transform: translateX(-50%); background: var(--smoke); border: 1px solid var(--line2); border-radius: 999px; padding: 5px 14px; font-size: 12px; color: var(--mint); }
</style>
