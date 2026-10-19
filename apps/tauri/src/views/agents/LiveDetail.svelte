<script lang="ts">
  // Een sessie die Nook via hooks of de proceslijst kent (`AgentSessionDetail` op de Mac): wat hij doet, wat hij
  // vraagt, het gesprek uit zijn transcript, en de knoppen om naar zijn terminal te gaan, hem over te nemen of te
  // beëindigen.
  import { agentApi, statusLabels, type AgentSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import ApprovalCard from "./ApprovalCard.svelte";
  import Conversation from "./Conversation.svelte";
  import DiffView from "./DiffView.svelte";
  import QuestionCard from "./QuestionCard.svelte";
  import { ago } from "./time";

  let { session, ontakeover }: { session: AgentSession; ontakeover?: (s: AgentSession, endTerminal: boolean, message?: string) => void } = $props();
  let canEnd = $state(false);
  let terminalName = $state("terminal");
  let message = $state("");
  let error = $state<string | null>(null);

  $effect(() => {
    agentApi.canEnd(session.id).then((v) => (canEnd = v));
    agentApi.terminalName(session.host).then((n) => (terminalName = n));
  });

  const approval = $derived(agents.approvalFor(session.id));
  const question = $derived(agents.questionFor(session.id));
  const canNook = $derived(["Claude Code", "Claude (app)", "Codex"].includes(session.name) && !!session.cwd);
  const busy = $derived(session.status === "running" || session.status === "waiting");

  async function end() {
    if (!confirm(`${session.name} in ${session.project} beëindigen? De agent bewaart zijn gesprek, zodat je later verder kunt.`)) return;
    try {
      await agentApi.end(session.id);
    } catch (e) {
      error = String(e);
    }
  }

  async function terminal() {
    try {
      await agentApi.activateTerminal(session.host);
    } catch {
      error = `Ik vind de terminal van ${session.name} niet. Staat hij nog open?`;
    }
  }

  function send() {
    const text = message.trim();
    if (!text || !ontakeover) return;
    ontakeover(session, false, text);
    message = "";
  }
</script>

<div class="detail">
  <header>
    <div class="title">{session.lastPrompt || session.summary || session.name}</div>
    <div class="meta faint">
      <span class="dot {session.status === 'waiting' ? 'waiting' : session.status === 'running' ? 'working' : session.status === 'failed' ? 'error' : session.status === 'done' ? 'unread' : ''}"></span>
      {session.name} · {session.project} · {statusLabels[session.status]}{#if session.updated} · {ago(session.updated)}{/if}
      {#if session.linesAdded + session.linesRemoved > 0}<span> · <span class="add">+{session.linesAdded}</span> <span class="rem">−{session.linesRemoved}</span></span>{/if}
    </div>
  </header>

  {#if approval}<ApprovalCard {approval} />{/if}
  {#if question}{#key question.id}<QuestionCard request={question} />{/key}{/if}

  {#if session.status === "detected"}
    <p class="muted">
      {#if canNook}
        Nook ziet dat {session.name} draait, maar kan niet meekijken. Neem hem over: de oude sessie sluit af en het gesprek
        gaat hier verder, met goedkeuringen en stoppen vanuit Nook.
      {:else}
        Nook ziet dat {session.name} draait, maar kan niet meekijken of hem voortzetten. Je kunt de sessie wel beëindigen.
      {/if}
    </p>
    <p class="faint small">{session.isLinked ? `Sluit ${session.name} en start hem opnieuw, dan volgt Nook hem.` : `Koppel ${session.name} bij Instellingen › Agents zodat Nook nieuwe sessies vanaf de start volgt.`}</p>
  {/if}

  <div class="scroll">
    {#if session.transcriptPath}
      <Conversation path={session.transcriptPath} refreshKey={session.updated ?? ""} />
    {:else}
      <div class="steps">
        {#each session.steps as step, i (i)}
          <div class="step {step.mark}"><span class="mark">{step.mark === "done" ? "✓" : step.mark === "running" ? "◐" : step.mark === "blocked" ? "●" : step.mark === "failed" ? "✗" : "○"}</span>{step.text}</div>
        {/each}
      </div>
      {#if session.lastReply}<p class="reply">{session.lastReply}</p>{/if}
    {/if}
    {#if session.diff.length && session.status !== "done" && session.status !== "failed" && session.transcriptPath}
      <DiffView lines={session.diff} max={220} />
    {/if}
  </div>

  {#if error}<p class="err">{error}</p>{/if}

  {#if canNook && ontakeover && session.status !== "detected"}
    <div class="reply-box">
      <input
        placeholder={busy ? "Stuur een bericht (Nook gaat verder met een kopie)…" : "Ga verder met deze sessie in Nook…"}
        bind:value={message}
        onkeydown={(e) => e.key === "Enter" && send()}
      />
      <button class="primary" disabled={!message.trim()} onclick={send}>Stuur</button>
    </div>
    {#if busy}<p class="faint small">De sessie is nog bezig: Nook gaat verder met een kopie van het gesprek, zodat ze elkaar niet storen.</p>{/if}
  {/if}

  <div class="actions">
    {#if session.host && session.status !== "detected"}<button onclick={terminal}>Open {terminalName}</button>{/if}
    {#if canNook && ontakeover}
      <button onclick={() => ontakeover?.(session, true)} disabled={!canEnd}>Neem over in Nook</button>
    {/if}
    <span class="spacer"></span>
    {#if canEnd}<button class="ghost danger" onclick={end}>Beëindig sessie</button>{/if}
  </div>
</div>

<style>
  .detail { display: flex; flex-direction: column; gap: 10px; height: 100%; min-height: 0; }
  header .title { font-weight: 600; font-size: 15px; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .meta { display: flex; align-items: center; gap: 6px; font-size: 12px; margin-top: 2px; }
  .add { color: var(--mint); }
  .rem { color: var(--coral); }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
  .steps { display: flex; flex-direction: column; gap: 3px; font-size: 12.5px; }
  .step .mark { display: inline-block; width: 18px; }
  .step.done .mark { color: var(--mint); }
  .step.running .mark { color: var(--paper); }
  .step.blocked .mark { color: var(--amber); }
  .step.failed .mark { color: var(--coral); }
  .step.todo { color: var(--text3); }
  .reply { white-space: pre-wrap; user-select: text; color: var(--text2); }
  .reply-box { display: flex; gap: 6px; }
  .reply-box input { flex: 1; }
  .actions { display: flex; gap: 6px; align-items: center; }
  .spacer { flex: 1; }
  .small { font-size: 12px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
