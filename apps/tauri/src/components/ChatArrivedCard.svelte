<script lang="ts">
  // What a chat that just wrote shows in the bar's card (the Mac's `showChatCard`, the same for every chat app but
  // WhatsApp, which has its own; the bar puts it beside Nook in a `BarCard`): the app and how many are new, who, the last
  // messages as bubbles with their time, a field to answer, Read and Later side by side, Let Nook answer, and "…" to open
  // the chat in Nook.
  import { tr, locale } from "../lib/i18n.svelte";
  import { arrivedChat } from "../lib/chat-arrived.svelte";
  import { appName, chatApps } from "../lib/chats-list";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";
  import { nook } from "../lib/state.svelte";
  import Menu from "./ui/Menu.svelte";
  import Ico from "./ui/Ico.svelte";

  // `onnook`: where Let Nook answer goes; by default a new Nook in this window is asked.
  let { onopen, onnook }: { onopen: (key: string) => void; onnook?: (prompt: string) => void } = $props();
  const thread = $derived(arrivedChat.thread);
  const recent = $derived((thread?.messages ?? []).filter((m) => !m.deleted).slice(-6));
  const clock = (iso: string | undefined) => (iso ? new Date(iso).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }) : "");
  const newCount = $derived(thread?.read.state === "unread" ? thread.read.count : 0);
  let more = $state<DOMRect | null>(null);

  function letNookAnswer() {
    if (!thread) return;
    const prompt = tr("Schrijf een kort antwoord aan {name} op {app} dat ik kan versturen.", "Write a short reply to {name} on {app} that I can send.", { name: thread.name, app: appName(thread.app) });
    arrivedChat.markRead();
    if (onnook) return onnook(prompt);
    nook.newNook().then(() => nook.ask(prompt)).catch((e) => (nook.error = String(e)));
  }
</script>

{#if thread}
  <div class="arrived">
    <div class="head">
      <ServiceIcon domain={chatApps[thread.app]?.domain} title={appName(thread.app)} size={14} />
      <span class="context">{appName(thread.app)}{#if newCount > 1} · {tr("{n} nieuw", "{n} new", { n: newCount })}{/if}</span>
    </div>
    <div class="title">{thread.name}</div>
    <div class="bubbles">
      {#each recent as m (m.id)}
        <div class="bubble" class:mine={m.fromMe}>
          {#if !m.fromMe && m.sender && m.sender !== thread.name}<em>{m.sender}</em>{/if}
          <span class="text">{m.text || "📎"}</span><span class="time">{clock(m.date)}</span>
        </div>
      {/each}
    </div>
    {#if thread.sends}
      <form class="reply" onsubmit={(e) => { e.preventDefault(); arrivedChat.send(); }}>
        <input bind:value={arrivedChat.draft} placeholder={tr("Antwoord {name}…", "Answer {name}…", { name: thread.name })} aria-label={tr("Antwoord {name}…", "Answer {name}…", { name: thread.name })} disabled={arrivedChat.sending} />
        <button class="send" type="submit" disabled={!arrivedChat.draft.trim() || arrivedChat.sending} aria-label={tr("Versturen", "Send")}><Ico name="arrow-up" size={13} /></button>
      </form>
    {/if}
    {#if arrivedChat.error}<span class="error">{arrivedChat.error}</span>{/if}
    <div class="buttons">
      <div class="pair">
        <button class="first" onclick={() => arrivedChat.markRead()}>{tr("Gelezen", "Read")}</button>
        <button onclick={() => arrivedChat.dismiss()}>{tr("Later", "Later")}</button>
      </div>
      <button class="nook" onclick={letNookAnswer}><Ico name="sparkles" size={14} />{tr("Laat Nook antwoorden", "Let Nook answer")}</button>
      <span class="spacer"></span>
      <button class="icon" aria-label={tr("Meer", "More")} title={tr("Meer", "More")} onclick={(e) => (more = (e.currentTarget as HTMLElement).getBoundingClientRect())}><Ico name="ellipsis" size={15} /></button>
    </div>
  </div>
  {#if more}
    <Menu anchor={more} onclose={() => (more = null)} sections={[[{ label: tr("Open in Nook", "Open in Nook"), icon: "messages-square", onselect: () => onopen(thread.key) }]]} />
  {/if}
{/if}

<style>
  .arrived { display: flex; flex-direction: column; gap: var(--space-8); }
  .head { display: flex; align-items: center; gap: var(--space-6); }
  .context { font: var(--text-label); color: var(--text2); }
  .title { font: var(--text-heading); color: var(--paper); }
  .bubbles { display: flex; flex-direction: column; gap: var(--space-6); max-height: 220px; overflow-y: auto; padding-bottom: var(--space-8); }
  .bubble { align-self: flex-start; max-width: 85%; display: inline-flex; align-items: baseline; flex-wrap: wrap; gap: var(--space-8); padding: var(--space-6) var(--space-12); border-radius: var(--radius-chat-bubble); background: var(--chat-theirs); color: var(--paper); font: var(--text-body); }
  .bubble.mine { align-self: flex-end; background: var(--chat-mine); }
  .bubble em { flex-basis: 100%; font-style: normal; font: var(--text-label); color: var(--text2); }
  .text { white-space: pre-wrap; overflow-wrap: anywhere; }
  .time { font: var(--text-caption); color: var(--text3); }
  .reply { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-panel); background: var(--field); }
  .reply input { flex: 1; min-width: 0; border: 0; background: transparent; padding: var(--space-6) 0; font: var(--text-body); }
  .reply input:focus { outline: none; }
  .send { display: grid; place-items: center; width: 30px; height: 30px; padding: 0; border-radius: 50%; border: 0; background: var(--smoke); color: var(--paper); }
  .send:disabled { opacity: 0.5; }
  .error { font: var(--text-detail); color: var(--coral); }
  .buttons { display: flex; align-items: center; gap: var(--space-12); }
  .pair { display: inline-flex; padding: var(--space-2); border-radius: var(--radius-card); background: var(--graphite); border: 1px solid var(--line2); }
  .pair button { height: 32px; padding: 0 var(--space-16); border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); font: var(--text-emphasis); font-weight: 600; }
  .pair button.first { background: var(--paper); color: var(--ink); }
  .nook { display: inline-flex; align-items: center; gap: var(--space-6); border: 0; background: transparent; color: var(--text-strong); font: var(--text-emphasis); font-weight: 600; }
  .nook:hover { color: var(--paper); }
  .spacer { flex: 1; }
  .icon { display: grid; place-items: center; width: 30px; height: 30px; padding: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text3); }
  .icon:hover { color: var(--paper); background: var(--smoke); }
</style>
