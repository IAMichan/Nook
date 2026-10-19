<script lang="ts">
  // Een eerdere sessie uit het transcript van de agent: het hele gesprek, en verdergaan (in Nook of in de terminal).
  import { agentApi, agentNames, formatTokens, total, type PastSession } from "../../lib/agents";
  import Conversation from "./Conversation.svelte";
  import { ago, duration, folderName } from "./time";

  let { session, oncontinue }: { session: PastSession; oncontinue?: (s: PastSession, message?: string) => void } = $props();
  let error = $state<string | null>(null);
  let message = $state("");

  const seconds = $derived((new Date(session.ended).getTime() - new Date(session.started).getTime()) / 1000);
  const command = $derived(
    session.agent === "codex" ? `codex resume ${session.sessionId}` : `${session.agent === "claude" ? "claude" : session.agent} --resume ${session.sessionId}`,
  );

  async function inTerminal() {
    try {
      await agentApi.runInTerminal(command, session.lastCwd || session.cwd);
    } catch (e) {
      error = String(e);
    }
  }

  function send() {
    const text = message.trim();
    if (!text || !oncontinue) return;
    oncontinue(session, text);
    message = "";
  }
</script>

<div class="detail">
  <header>
    <div class="title">{session.title || "Sessie zonder titel"}</div>
    <div class="meta faint">
      {agentNames[session.agent]} · {folderName(session.cwd)}{#if session.branch} · {session.branch}{/if} · {ago(session.ended)} · duurde {duration(seconds)} · {session.prompts} vragen
      {#if total(session.tokens)} · {formatTokens(total(session.tokens))} tokens{/if}
    </div>
  </header>
  <div class="scroll"><Conversation path={session.path} /></div>
  {#if error}<p class="err">{error}</p>{/if}
  {#if oncontinue}
    <div class="reply-box">
      <input placeholder="Ga verder met deze sessie in Nook…" bind:value={message} onkeydown={(e) => e.key === "Enter" && send()} />
      <button class="primary" disabled={!message.trim()} onclick={send}>Stuur</button>
    </div>
  {/if}
  <div class="actions">
    {#if oncontinue}<button onclick={() => oncontinue?.(session)}>Open in Nook</button>{/if}
    <button onclick={inTerminal}>Ga verder in de terminal</button>
  </div>
</div>

<style>
  .detail { display: flex; flex-direction: column; gap: 10px; height: 100%; min-height: 0; }
  .title { font-weight: 600; font-size: 15px; }
  .meta { font-size: 12px; margin-top: 2px; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; }
  .reply-box { display: flex; gap: 6px; }
  .reply-box input { flex: 1; }
  .actions { display: flex; gap: 6px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
