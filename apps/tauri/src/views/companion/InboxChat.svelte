<script lang="ts">
  // One chat of the Chats tab as bubbles: quotes, reactions, ticks, files by name. A chat the computer can write in
  // (WhatsApp through the linked phone) is answered from here with your own words and your own tap, also as a reply to
  // one of its messages (touch and hold it); any other chat says so at its end and is answered in its own app.
  import { onMount } from "svelte";
  import { companion, shortTime, ticksMark, type ClientView, type InboxChatDigest, type InboxLine, type InboxTypist } from "../../lib/companion";
  import { onBack } from "../../lib/mobile";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";

  let { view, id, chat, onback, took }: {
    view: ClientView;
    id: string;
    chat: InboxChatDigest | null;
    onback: () => void;
    took: (v: ClientView) => void;
  } = $props();

  let lines = $state<InboxLine[]>([]);
  let typing = $state<InboxTypist[]>([]);
  let loaded = $state(false);
  let text = $state("");
  let replyTo = $state<InboxLine | null>(null);
  let sending = $state(false);
  let menu = $state(false);
  let press: ReturnType<typeof setTimeout> | undefined;

  $effect(() => onBack(() => {
    if (menu) return (menu = false), true;
    if (replyTo) return (replyTo = null), true;
    onback();
    return true;
  }));

  async function load() {
    if (document.visibilityState !== "visible") return;
    const r = await companion.call({ op: "inboxChat", item: id });
    if (r.response?.inboxLines) lines = r.response.inboxLines;
    typing = r.response?.inboxTyping ?? [];
    loaded = true;
    if (!r.response) took(r.view);
  }

  onMount(() => {
    load();
    const timer = setInterval(load, 5000);
    return () => clearInterval(timer);
  });

  async function send() {
    const words = text.trim();
    if (!words || sending) return;
    sending = true;
    const r = await companion.call({ op: "inboxSend", item: id, text: words, replyTo: replyTo?.id });
    sending = false;
    took(r.view);
    if (!r.response) return;
    text = "";
    replyTo = null;
    if (r.response.inboxLines) lines = r.response.inboxLines;
  }

  async function mark(read: boolean) {
    menu = false;
    const r = await companion.call({ op: "inboxMark", item: id, allow: read });
    took(r.view);
    if (r.response && !read) onback();
  }

  function hold(line: InboxLine) {
    if (!chat?.canSend) return;
    clearTimeout(press);
    press = setTimeout(() => (replyTo = line), 450);
  }
  const release = () => clearTimeout(press);
  const typingWord = (t: InboxTypist[]) => {
    const who = t.map((x) => x.name).filter(Boolean).join(", ");
    return who ? tr("{who} typt…", "{who} is typing…", { who }) : tr("typt…", "typing…");
  };
</script>

<div class="chat">
  <header>
    <button class="ghost back" onclick={onback} aria-label={tr("Terug", "Back")}><Icon name="back" size={20} /></button>
    <span class="who"><strong>{chat?.name ?? tr("Chat", "Chat")}</strong>{#if chat}<span class="faint">{typing.length ? typingWord(typing) : chat.appName}</span>{/if}</span>
    <button class="ghost icon" onclick={() => (menu = !menu)} aria-expanded={menu} aria-label={tr("Meer", "More")}>⋯</button>
  </header>
  {#if menu}
    <div class="menu">
      <button onclick={() => mark(true)}>{tr("Markeer als gelezen", "Mark as read")}</button>
      <button onclick={() => mark(false)}>{tr("Markeer als ongelezen", "Mark as unread")}</button>
    </div>
  {/if}
  <ConversationScroll version={[lines.length, lines[lines.length - 1]?.id]}>
    {#if !loaded}<p class="faint">{tr("Laden…", "Loading…")}</p>{/if}
    {#each lines as l (l.id)}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="bubble" class:mine={l.fromMe} onpointerdown={() => hold(l)} onpointerup={release} onpointerleave={release} oncontextmenu={(e) => { if (chat?.canSend) { e.preventDefault(); replyTo = l; } }}>
        {#if l.sender && !l.fromMe}<span class="sender">{l.sender}</span>{/if}
        {#if l.quoteText}<span class="quote"><strong>{l.quoteSender ?? ""}</strong> {l.quoteText}</span>{/if}
        {#if l.attachment}<span class="file">📎 {l.attachment}</span>{/if}
        {#if l.text}<span class="words">{l.text}</span>{/if}
        <span class="stamp">{shortTime(l.date)}{#if l.fromMe && l.ticks} <span class:read={l.ticks === "read"}>{ticksMark(l.ticks)}</span>{/if}</span>
        {#if l.reactions.length}<span class="reactions">{l.reactions.join(" ")}</span>{/if}
      </div>
    {/each}
    {#if loaded && chat && !chat.canSend}
      <p class="faint end">{tr("Deze chat kun je hier alleen lezen. Antwoord in {app}, of koppel {app} in Nook › Instellingen › Chat-apps op je computer.", "You can only read this chat here. Answer in {app}, or link {app} in Nook › Settings › Chat apps on your computer.", { app: chat.appName })}</p>
    {/if}
  </ConversationScroll>
  {#if chat?.canSend}
    <div class="composer">
      {#if replyTo}
        <div class="replying">
          <span class="faint">{tr("Antwoord op", "Replying to")} <strong>{replyTo.fromMe ? tr("jezelf", "yourself") : replyTo.sender || chat.name}</strong>: {replyTo.text || replyTo.attachment}</span>
          <button class="ghost" onclick={() => (replyTo = null)} aria-label={tr("Annuleer", "Cancel")}><Icon name="x" size={14} /></button>
        </div>
      {/if}
      <div class="field">
        <textarea rows="1" placeholder={tr("Bericht", "Message")} bind:value={text} disabled={sending}></textarea>
        <button class="primary send" disabled={!text.trim() || sending} onclick={send} aria-label={tr("Verstuur", "Send")}><Icon name="arrow" size={18} /></button>
      </div>
    </div>
  {/if}
</div>

<style>
  .chat { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: var(--space-4); padding: var(--space-4) var(--space-4); border-bottom: 1px solid var(--line); }
  .back, .icon { min-width: 44px; min-height: 44px; }
  .who { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .who strong { font: var(--text-title); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .who span { font: var(--text-detail); }
  .menu { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8) var(--space-12); border-bottom: 1px solid var(--line); }
  .menu button { min-height: 44px; text-align: left; }
  .bubble { align-self: flex-start; max-width: 82%; display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-6) var(--space-12); border-radius: var(--radius-chat-bubble); background: var(--chat-theirs); user-select: text; -webkit-touch-callout: none; }
  .bubble.mine { align-self: flex-end; background: var(--chat-mine); }
  .sender { font: var(--text-label); color: var(--mint-soft); }
  .quote { font: var(--text-detail); color: var(--text2); border-left: 2px solid var(--line2); padding-left: var(--space-6); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .file { font: var(--text-detail); }
  .words { font: var(--text-body); white-space: pre-wrap; overflow-wrap: anywhere; }
  .stamp { align-self: flex-end; font: var(--text-caption); color: var(--chat-stamp); }
  .stamp .read { color: var(--blue); }
  .reactions { font: var(--text-detail); }
  .end { text-align: center; font: var(--text-detail); margin: var(--space-8) 0 0; }
  p { margin: 0; }
  .composer { border-top: 1px solid var(--line); padding: var(--space-8) var(--space-12) var(--space-12); display: flex; flex-direction: column; gap: var(--space-6); }
  .replying { display: flex; align-items: center; gap: var(--space-8); font: var(--text-detail); }
  .replying span { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .field { display: flex; gap: var(--space-8); align-items: flex-end; background: var(--composer); border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); }
  .field textarea { flex: 1; resize: none; min-height: 36px; max-height: 160px; border: none; background: transparent; padding: var(--space-8) 0; field-sizing: content; }
  .send { width: 40px; height: 40px; border-radius: 50%; padding: 0; display: flex; align-items: center; justify-content: center; flex: none; }
</style>
