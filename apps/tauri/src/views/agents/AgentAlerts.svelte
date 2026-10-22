<script lang="ts">
  // Wat een agent van je wil, bovenaan de open balk: eerst toestemmingsvragen, dan meerkeuzevragen, dan het kaartje
  // "klaar / liep vast / wacht op je" met wat hij zei. Beantwoord je in de terminal, dan verdwijnt de kaart vanzelf.
  // A question takes one compact bar here, like on the Mac: View opens the session to answer it, so the open panel
  // stays as it was. The notice card groups its actions in one bar next to a white OK with the countdown.
  import { agentApi, type QuestionRequest } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { compactNotice, noticeTone } from "../../lib/notice";
  import NoticeMark from "../../components/NoticeMark.svelte";
  import NoticeOk from "../../components/NoticeOk.svelte";
  import ApprovalCard from "./ApprovalCard.svelte";

  // `requests`: ook toestemmingsvragen en meerkeuzevragen tonen (niet als de tab Agents ze zelf al toont).
  // `left`: what is left of the notice's countdown (1 to 0), for the ring on OK; `ondismiss`: OK or Esc.
  // `compact`: the notice as one line (Settings › Meldingen).
  let {
    onview,
    requests = true,
    left = null,
    compact = false,
    ondismiss = () => (agents.attention = null),
  }: { onview: (sessionId: string) => void; requests?: boolean; left?: number | null; compact?: boolean; ondismiss?: () => void } =
    $props();

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

  function view() {
    if (!card) return;
    onview(card.id);
    agents.attention = null;
  }

  async function answerInTerminal(request: QuestionRequest) {
    const host = agents.sessions.find((s) => s.id === request.sessionKey)?.host ?? "";
    try {
      await agentApi.answerInTerminal(request.id);
      if (host) await agentApi.activateTerminal(host);
    } catch (e) {
      agents.error = String(e);
    }
    agents.refresh();
  }
</script>

{#if approval}
  <div class="alert"><ApprovalCard {approval} others={agents.approvals.length - 1} compact /></div>
{:else if question}
  <div class="alert">
    <div class="qbar">
      <NoticeMark tone="waiting" />
      <div class="qtext">
        <div class="qtitle" title={question.items[0]?.question ?? ""}>{question.items[0]?.question ?? ""}</div>
        <div class="faint qsub">
          {question.agentName} vraagt · {question.project}{#if agents.questions.length > 1} · nog {agents.questions.length - 1}{/if}
        </div>
      </div>
      {#if !question.sessionKey.startsWith("run:")}<button class="ghost" onclick={() => answerInTerminal(question)}>In terminal</button>{/if}
      <button class="primary" onclick={() => onview(question.sessionKey)}>Bekijk</button>
    </div>
  </div>
{:else if card && compact}
  <div class="alert">
    <div class="qbar">
      <NoticeMark tone={noticeTone(card.status)} />
      <div class="qtext"><div class="qtitle">{compactNotice(card.name, card.project, card.status)}</div></div>
      <button class="ghost" onclick={view}>Bekijk</button>
      <NoticeOk compact {left} onclick={ondismiss} />
    </div>
  </div>
{:else if card}
  <div class="alert">
    <div class="status" class:done={card.status === "done"} class:failed={card.status === "failed"}>
      <div class="context faint">
        <span class="dot {card.status === 'done' ? 'unread' : card.status === 'failed' ? 'error' : 'waiting'}"></span>
        {card.name} · {card.project} · {stateText}{#if card.linesAdded + card.linesRemoved > 0} · +{card.linesAdded} −{card.linesRemoved}{/if}
      </div>
      <div class="title">{card.summary || fallback}</div>
      <div class="buttons">
        <div class="actions">
          <button class="action bright" onclick={view}>Bekijk</button>
          {#if card.host}<span class="divider"></span><button class="action" onclick={openTerminal}>Open {terminalName}</button>{/if}
        </div>
        <NoticeOk {left} onclick={ondismiss} />
      </div>
    </div>
  </div>
{/if}

<style>
  .alert { padding: 4px 12px 8px; }
  .status { background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 12px 14px; display: flex; flex-direction: column; gap: 8px; }
  .status.done { border-color: color-mix(in srgb, var(--mint) 40%, var(--line2)); }
  .status.failed { border-color: color-mix(in srgb, var(--coral) 45%, var(--line2)); }
  .context { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .title { font-weight: 600; font-size: 14px; line-height: 1.35; }
  .buttons { display: flex; gap: 10px; align-items: center; }
  /* The notice's other actions side by side in one dark bar, split by thin lines; the first reads brightest. */
  .actions {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    height: 40px;
    padding: 0 4px;
    background: var(--graphite);
    border: 1px solid var(--line2);
    border-radius: 999px;
  }
  .action { flex: 1; min-width: 0; background: transparent; border: none; border-radius: 999px; color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .action.bright { color: var(--paper); font-weight: 600; }
  .action:hover { background: var(--smoke); color: var(--paper); }
  .divider { width: 1px; height: 18px; background: var(--line2); flex: none; }
  .qbar { display: flex; align-items: center; gap: 8px; background: var(--field); border: 1px solid var(--line2); border-radius: 10px; padding: 7px 10px; }
  .qtext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .qtitle { font-size: 12.5px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .qsub { font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
</style>
