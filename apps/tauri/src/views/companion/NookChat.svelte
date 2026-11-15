<script lang="ts">
  // A chat with Nook on your computer (`ChatView`): your words and Nook's answers as in a session, "Thinking…" with Nook's
  // face while it writes, and Ask Nook at the bottom, Stop while it writes. A plan, draft or chart waits on the computer.
  import { onMount, untrack } from "svelte";
  import { companion, messageTime, type ChatLine, type ClientView } from "../../lib/companion";
  import { renderMarkdown } from "../../lib/markdown";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NavBar from "./ui/NavBar.svelte";
  import NookMark from "./ui/NookMark.svelte";
  import PulseDot from "./ui/PulseDot.svelte";
  import Ico from "./ui/Ico.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";

  let { view, id: initial, ask: question, onback, took }: {
    view: ClientView; id: string | null; ask?: string; onback: () => void; took: (v: ClientView) => void;
  } = $props();

  let id = $state<string | null>(untrack(() => initial));
  let title = $state("");
  let lines = $state<ChatLine[]>([]);
  let text = $state("");
  let sending = $state(false);
  const busy = $derived(sending || lines.some((l) => l.streaming));
  const last = $derived(lines[lines.length - 1]);
  const queued = $derived((view.outbox ?? []).filter((q) => q.op === "ask" && (q.conversation ?? null) === id));
  const thinking = $derived(sending || (last?.fromNook && last.streaming && !last.text));

  async function load() {
    if (!id || document.visibilityState !== "visible") return;
    const r = await companion.call({ op: "chat", conversation: id });
    if (r.response?.messages) lines = r.response.messages;
  }
  async function loadTitle() {
    const r = await companion.call({ op: "chats" });
    title = r.response?.conversations?.find((c) => c.id === id)?.title ?? "";
  }

  // While Nook writes, ask every 1.5 seconds; otherwise every 6.
  $effect(() => {
    if (!id) return;
    const timer = setInterval(load, busy ? 1500 : 6000);
    return () => clearInterval(timer);
  });

  async function send(words: string) {
    if (sending) return;
    sending = true;
    haptic();
    const r = await companion.call({ op: "ask", conversation: id ?? undefined, text: words });
    sending = false;
    took(r.view);
    if (!r.response) return;
    text = "";
    if (r.response.created) id = r.response.created;
    if (r.response.messages) lines = r.response.messages;
    else load();
    if (!title) loadTitle();
  }

  async function stop() {
    if (!id) return;
    const r = await companion.call({ op: "chatStop", conversation: id });
    took(r.view);
    if (r.response?.messages) lines = r.response.messages;
  }

  onMount(() => {
    if (initial) { load(); loadTitle(); }
    else if (question) send(question);
  });
</script>

<div class="chat">
  <NavBar onback={onback}>
    {#snippet center()}<span class="t"><strong>{title || tr("Nieuwe chat", "New chat")}</strong><small>Nook</small></span>{/snippet}
  </NavBar>
  <ConversationScroll version={[lines.length, last?.text.length, last?.status, sending]}>
    <div class="lines">
      {#each lines as l (l.id)}
        {#if !l.fromNook}
          <div class="user"><div class="bubble">{l.text}</div><span class="time">{messageTime(l.date)}</span></div>
        {:else if l.text}
          <div class="answer" class:failed={l.failed}>
            <div class="markdown">{@html renderMarkdown(l.text)}</div>
            {#if !l.streaming}<span class="time">{messageTime(l.date)}</span>{/if}
            {#if l.onMac}<div class="onmac"><span style:color="var(--amber)"><Ico name="laptop" size={13} /></span>{tr("Nook maakte een plan, concept of grafiek: bekijk het op je Mac.", "Nook made a plan, draft or chart: see it on your Mac.")}</div>{/if}
          </div>
        {/if}
      {/each}
      {#each queued as q (q.id)}
        <div class="user waiting"><div class="bubble">{q.text}</div><span class="time"><Ico name="clock" size={11} /> {tr("Wacht op je Mac", "Waiting for your Mac")}</span></div>
      {/each}
      {#if thinking}
        <div class="thinking"><NookMark size={22} /><span>{last?.status || tr("Aan het denken…", "Thinking…")}</span><PulseDot size={5} color="var(--text2)" /></div>
      {/if}
    </div>
  </ConversationScroll>
  <div class="dock">
    <SessionComposer bind:value={text} placeholder={tr("Vraag Nook", "Ask Nook")} onsend={send} onstop={busy ? stop : undefined} />
  </div>
</div>

<style>
  .chat { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .t { display: flex; flex-direction: column; align-items: center; max-width: 240px; min-width: 0; }
  .t strong { font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
  .t small { font: var(--pt-caption); color: var(--text3); }
  .lines { display: flex; flex-direction: column; gap: 24px; }
  .user { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; padding-left: 56px; }
  .bubble { background: var(--bubble); border-radius: 16px; padding: 12px; font: var(--pt-body); line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; }
  .waiting { opacity: 0.6; }
  .time { font: var(--pt-caption); color: var(--text3); }
  .answer { display: flex; flex-direction: column; gap: 4px; font: var(--pt-body); color: var(--text-strong); overflow-wrap: anywhere; }
  .answer.failed { color: var(--coral); }
  .answer :global(.markdown a) { color: var(--blue); }
  .onmac { display: flex; align-items: baseline; gap: 6px; padding: 12px; background: var(--field); border-radius: 12px; font: var(--pt-detail); color: var(--text-strong); }
  .thinking { display: flex; align-items: center; gap: 8px; font: var(--pt-detail); color: var(--text2); }
  .dock { padding: 8px 12px; background: linear-gradient(transparent, var(--canvas) 30%); }
</style>
