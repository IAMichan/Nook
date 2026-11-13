<script lang="ts">
  // Een eerdere sessie uit het transcript van de agent: het hele gesprek, en verdergaan (in Nook of in de terminal).
  import { agentApi, agentNames, formatTokens, total, type PastSession } from "../../lib/agents";
  import Conversation from "./Conversation.svelte";
  import { tr } from "../../lib/i18n.svelte";
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
  <header class="thread-head">
    <div class="title"><span class="project">{folderName(session.cwd)}</span><span class="slash">/</span><span class="name">{session.title || tr("Sessie zonder titel", "Untitled session")}</span></div>
    <div class="meta faint">
      {agentNames[session.agent]} · {folderName(session.cwd)}{#if session.branch} · {session.branch}{/if} · {ago(session.ended)} · {tr("duurde {time}", "took {time}", { time: duration(seconds) })} · {tr("{n} vragen", "{n} prompts", { n: session.prompts })}
      {#if total(session.tokens)} · {tr("{n} tokens", "{n} tokens", { n: formatTokens(total(session.tokens)) })}{/if}
    </div>
  </header>
  <div class="scroll"><div class="thread-column body"><Conversation path={session.path} /></div></div>
  <div class="thread-column foot">
  {#if error}<p class="err">{error}</p>{/if}
  {#if oncontinue}
    <div class="reply-box">
      <input placeholder={tr("Ga verder met deze sessie in Nook…", "Continue this session in Nook…")} bind:value={message} onkeydown={(e) => e.key === "Enter" && send()} />
      <button class="primary" disabled={!message.trim()} onclick={send}>{tr("Stuur", "Send")}</button>
    </div>
  {/if}
  <div class="actions">
    {#if oncontinue}<button onclick={() => oncontinue?.(session)}>{tr("Open in Nook", "Open in Nook")}</button>{/if}
    <button onclick={inTerminal}>{tr("Ga verder in de terminal", "Continue in the terminal")}</button>
  </div>
  </div>
</div>

<style>
  .detail { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .thread-head { display: flex; align-items: center; gap: 12px; min-height: 52px; padding: 0 16px; flex: none; }
  .thread-head .title { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1; font-size: 14px; }
  .project { color: var(--text2); white-space: nowrap; max-width: 160px; overflow: hidden; text-overflow: ellipsis; flex: none; }
  .slash { color: var(--text3); }
  .name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta { font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 50%; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; }
  .body { padding-top: 8px; padding-bottom: 16px; }
  .foot { display: flex; flex-direction: column; gap: 8px; padding-bottom: 12px; flex: none; }
  .reply-box { display: flex; gap: 6px; align-items: center; padding: 6px 6px 6px 14px; border: 1px solid var(--line2); border-radius: var(--radius-composer); background: var(--surface); }
  .reply-box:focus-within { border-color: color-mix(in srgb, var(--paper) 22%, var(--line2)); }
  .reply-box input { flex: 1; border: 0; background: transparent; padding: 6px 0; font-size: 14px; }
  .reply-box input:focus-visible { box-shadow: none; }
  .reply-box button { border-radius: 999px; height: 32px; padding: 0 14px; }
  .actions { display: flex; gap: 6px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
