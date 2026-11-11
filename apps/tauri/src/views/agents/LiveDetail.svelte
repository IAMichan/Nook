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
  const canNook = $derived(["Claude Code", "Claude (app)", "Codex", "Gemini CLI"].includes(session.name) && !!session.cwd);
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
  <header class="thread-head">
    <div class="title"><span class="project">{session.project}</span><span class="slash">/</span><span class="name">{session.lastPrompt || session.summary || session.name}</span></div>
    <div class="meta faint">
      <span class="dot {session.status === 'waiting' ? 'waiting' : session.status === 'running' ? 'working' : session.status === 'failed' ? 'error' : session.status === 'done' ? 'unread' : ''}"></span>
      {session.name} · {statusLabels[session.status]}{#if session.updated} · {ago(session.updated)}{/if}
      {#if session.linesAdded + session.linesRemoved > 0}<span> · <span class="add">+{session.linesAdded}</span> <span class="rem">−{session.linesRemoved}</span></span>{/if}
    </div>
  </header>

  <div class="scroll">
  <div class="thread-column body">
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
  </div>

  <div class="thread-column foot">
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
</div>

<style>
  .detail { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  /* thread header: the project, a slash and the thread's name, its state on the right. */
  .thread-head { display: flex; align-items: center; gap: 12px; min-height: 52px; padding: 0 16px; flex: none; }
  .thread-head .title { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1; font-size: 14px; }
  .project { color: var(--text2); white-space: nowrap; max-width: 160px; overflow: hidden; text-overflow: ellipsis; flex: none; }
  .slash { color: var(--text3); }
  .name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta { display: flex; align-items: center; gap: 6px; font-size: 12px; white-space: nowrap; }
  .body { display: flex; flex-direction: column; gap: 12px; padding-top: 8px; padding-bottom: 16px; }
  .foot { display: flex; flex-direction: column; gap: 8px; padding-bottom: 12px; flex: none; }
  .add { color: var(--mint); }
  .rem { color: var(--coral); }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; }
  .steps { display: flex; flex-direction: column; gap: 4px; font-size: 14px; color: var(--text2); }
  .step .mark { display: inline-block; width: 18px; }
  .step.done .mark { color: var(--mint); }
  .step.running .mark { color: var(--paper); }
  .step.blocked .mark { color: var(--amber); }
  .step.failed .mark { color: var(--coral); }
  .step.todo { color: var(--text3); }
  .reply { white-space: pre-wrap; user-select: text; color: var(--text2); }
  /* The reply field in composer surface. */
  .reply-box { display: flex; gap: 6px; align-items: center; padding: 6px 6px 6px 14px; border: 1px solid var(--line2); border-radius: var(--radius-composer); background: var(--surface); }
  .reply-box:focus-within { border-color: color-mix(in srgb, var(--paper) 22%, var(--line2)); }
  .reply-box input { flex: 1; border: 0; background: transparent; padding: 6px 0; font-size: 14px; }
  .reply-box input:focus-visible { box-shadow: none; }
  .reply-box button { border-radius: 999px; height: 32px; padding: 0 14px; }
  .actions { display: flex; gap: 6px; align-items: center; }
  .spacer { flex: 1; }
  .small { font-size: 12px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
