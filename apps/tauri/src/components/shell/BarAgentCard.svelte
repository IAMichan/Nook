<script lang="ts">
  // An agent's notice as the bar's card (the Mac's `showAgentNotice`): the agent's logo with who and where, its changed
  // lines and its state in the header; what the session is about as the title and what it said under it; View, its
  // terminal where it runs in one, and OK with the countdown. The same for every agent.
  import { agentApi, type AgentSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { noticeTone } from "../../lib/notice";
  import AgentMark from "../../views/companion/ui/AgentMark.svelte";
  import { folderName } from "../../views/agents/time";
  import NoticeOk from "../NoticeOk.svelte";
  import Ico from "../ui/Ico.svelte";
  import BarCard from "./BarCard.svelte";

  let { card, left = null, height = $bindable(0), onview, ondismiss }:
    { card: AgentSession; left?: number | null; height?: number; onview: (id: string) => void; ondismiss: () => void } = $props();

  const tone = $derived(noticeTone(card.status));
  const where = $derived(card.cwd ? folderName(card.cwd) : card.project);
  // A session Nook runs carries its title in `project`; a terminal session its first prompt.
  const topic = $derived((card.id.startsWith("run:") ? card.project : card.lastPrompt).replace(/\s+/g, " ").trim().slice(0, 120));
  const said = $derived((card.lastReply || card.summary || "").replace(/\s+/g, " ").trim());
  const status = $derived(card.status === "done" ? tr("Klaar", "Done") : card.status === "failed" ? tr("Vastgelopen", "Stuck") : tr("Wacht op je", "Waiting for you"));
  let terminalName = $state("terminal");
  $effect(() => {
    if (card.host) agentApi.terminalName(card.host).then((n) => (terminalName = n)).catch(() => {});
  });

  async function openTerminal() {
    try {
      await agentApi.activateTerminal(card.host);
      ondismiss();
    } catch {
      agents.error = tr("Ik vind de terminal van {name} niet. Staat hij nog open?", "I can't find the terminal of {name}. Is it still open?", { name: card.name });
    }
  }
</script>

<BarCard mood={tone === "done" ? "done" : tone === "failed" ? "error" : "waiting"} tint={tone === "done" ? "var(--mint)" : tone === "failed" ? "var(--coral)" : "var(--amber)"} bind:height>
  <div class="head">
    <AgentMark agent={card.name} size={14} />
    <span class="context">{[card.name, where].filter(Boolean).join(" · ")}</span>
    <span class="spacer"></span>
    {#if card.linesAdded + card.linesRemoved > 0}<span class="lines"><span class="plus">+{card.linesAdded}</span> <span class="minus">−{card.linesRemoved}</span></span>{/if}
    <span class="status {tone}"><Ico name={tone === "done" ? "check" : tone === "failed" ? "alert-circle" : "message-circle"} size={11} stroke={2.4} />{status}</span>
  </div>
  <div class="title">{topic || said}</div>
  {#if topic && said && said !== topic}<div class="said">{said}</div>{/if}
  <div class="buttons">
    <button class="action" onclick={() => onview(card.id)}><Ico name="eye" size={14} />{tr("Bekijk", "View")}</button>
    {#if card.host}<button class="action" onclick={openTerminal}><Ico name="terminal" size={14} />{tr("Open {app}", "Open {app}", { app: terminalName })}</button>{/if}
    <NoticeOk square {left} onclick={ondismiss} />
  </div>
</BarCard>

<style>
  .head { display: flex; align-items: center; gap: var(--space-6); min-height: 20px; }
  .context { font: var(--text-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .spacer { flex: 1; }
  .lines { font: var(--text-label); font-family: var(--mono); }
  .plus { color: var(--added); }
  .minus { color: var(--removed); }
  .status { display: inline-flex; align-items: center; gap: var(--space-4); padding: var(--space-2) var(--space-6); border-radius: var(--radius-chip); font: var(--text-label); color: var(--mint); background: color-mix(in srgb, var(--mint) 14%, transparent); }
  .status.failed { color: var(--coral); background: color-mix(in srgb, var(--coral) 14%, transparent); }
  .status.waiting { color: var(--amber); background: color-mix(in srgb, var(--amber) 14%, transparent); }
  .title { font: var(--text-heading); color: var(--paper); line-height: 1.3; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .said { font: var(--text-body); color: var(--text2); line-height: 1.45; display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .buttons { display: flex; align-items: center; gap: var(--space-12); margin-top: var(--space-12); }
  .action { display: inline-flex; align-items: center; gap: var(--space-6); height: 36px; padding: 0 var(--space-16); border-radius: var(--radius-card); border: 1px solid var(--line2); background: var(--graphite); color: var(--paper); font: var(--text-emphasis); font-weight: 600; }
  .action:hover { background: var(--smoke); }
</style>
