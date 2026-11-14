<script lang="ts">
  // One chat as the iPhone shows it (`InboxChatView`): bubbles in runs (the first of a run with a tail and, in a group,
  // the sender), a day divider where a day starts, quotes, reactions and ticks. A WhatsApp chat wears WhatsApp's colors.
  // A chat the computer can write in is answered here, also as a reply to one of its messages (touch and hold it); any
  // other says how to answer it.
  import { onDestroy, onMount, untrack } from "svelte";
  import {
    companion, followsLive, personTint, typingText, Feature,
    type ClientView, type InboxChatDigest, type InboxLine, type InboxTypist,
  } from "../../lib/companion";
  import { locale, tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NavBar from "./ui/NavBar.svelte";
  import Ico from "./ui/Ico.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import TicksMark from "./ui/TicksMark.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";
  import { WA } from "./ui/whatsapp";

  let { view, id, chat, onback, took }: { view: ClientView; id: string; chat: InboxChatDigest | null; onback: () => void; took: (v: ClientView) => void } = $props();

  let lines = $state<InboxLine[]>([]);
  let typing = $state<InboxTypist[]>([]);
  let loaded = $state(false);
  let text = $state("");
  let replyTo = $state<InboxLine | null>(null);
  let sending = $state(false);
  let menu = $state<{ anchor: DOMRect; sections: MenuItem[][] } | null>(null);
  const wa = $derived(chat?.app === "whatsapp");
  const live = $derived(followsLive(view, Feature.liveChats));
  const group = $derived(lines.some((l) => !l.fromMe && l.sender));

  async function load() {
    if (document.visibilityState !== "visible") return;
    const r = await companion.call(untrack(() => live) ? { op: "watchChat", item: id } : { op: "inboxChat", item: id });
    if (r.response?.inboxLines) lines = r.response.inboxLines;
    typing = r.response?.inboxTyping ?? [];
    loaded = true;
    if (!r.response) took(r.view);
  }
  onMount(() => {
    load();
    const un = companion.onLive((r) => {
      if (r.inboxChat !== id) return;
      if (r.inboxLines) lines = r.inboxLines;
      typing = r.inboxTyping ?? [];
    });
    // Without a live connection: every 4 seconds, every 1.5 while someone types.
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => (timer = setTimeout(async () => { if (!untrack(() => live)) await load(); tick(); }, typing.length ? 1500 : 4000));
    tick();
    return () => { clearTimeout(timer); un.then((f) => f()); };
  });
  onDestroy(() => {
    if (untrack(() => live)) companion.call({ op: "watchChat" });
  });

  async function send(words: string) {
    if (sending) return;
    sending = true;
    const r = await companion.call({ op: "inboxSend", item: id, text: words, replyTo: replyTo?.id });
    sending = false;
    took(r.view);
    if (!r.response) return;
    haptic("success");
    text = "";
    replyTo = null;
    if (r.response.inboxLines) lines = r.response.inboxLines;
  }

  async function mark(read: boolean) {
    const r = await companion.call({ op: "inboxMark", item: id, allow: read });
    took(r.view);
    if (r.response && !read) onback();
  }

  // Runs: the same writer within five minutes on the same day.
  const day = (s: number) => new Date(s * 1000).toDateString();
  function first(i: number) {
    const a = lines[i - 1], b = lines[i];
    return !a || a.fromMe !== b.fromMe || a.sender !== b.sender || b.date - a.date > 300 || day(a.date) !== day(b.date);
  }
  function lastOfRun(i: number) {
    return i === lines.length - 1 || first(i + 1);
  }
  function dayLabel(s: number) {
    const d = new Date(s * 1000);
    if (d.toDateString() === new Date().toDateString()) return tr("Vandaag", "Today");
    if (d.toDateString() === new Date(Date.now() - 86_400_000).toDateString()) return tr("Gisteren", "Yesterday");
    return d.toLocaleDateString(locale(), { weekday: "long", day: "numeric", month: "long" });
  }
  const emojiOnly = (t: string) => !!t && [...t].length <= 3 && /^\p{Extended_Pictographic}[\p{Extended_Pictographic}‍️\s]*$/u.test(t);
  const time = (s: number) => new Date(s * 1000).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });

  let press: ReturnType<typeof setTimeout> | undefined;
  let start: { x: number; y: number } | null = null;
  function hold(e: PointerEvent, line: InboxLine) {
    clearTimeout(press);
    start = { x: e.clientX, y: e.clientY };
    const el = e.currentTarget as HTMLElement;
    press = setTimeout(() => {
      haptic();
      menu = { anchor: el.getBoundingClientRect(), sections: [[
        ...(chat?.canSend ? [{ label: tr("Beantwoord", "Reply"), icon: "reply", onselect: () => (replyTo = line) }] : []),
        { label: tr("Kopieer", "Copy"), icon: "copy", onselect: () => navigator.clipboard?.writeText(line.text).catch(() => {}) },
      ]] };
    }, 450);
  }
  function moved(e: PointerEvent) {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 8) release();
  }
  function release() {
    clearTimeout(press);
    start = null;
  }
  const typingNow = $derived(typingText(typing));
</script>

<div class="chat" class:wa style:background={wa ? WA.wallpaper : undefined}>
  <NavBar onback={onback} tint={wa ? WA.bar : undefined}>
    {#snippet center()}
      {#if chat}
        <span class="who" class:left={wa}>
          <InboxAvatar name={chat.name} app={chat.app} size={wa ? 36 : 30} badge={!wa} />
          <span class="t"><strong style:color={wa ? WA.text : undefined}>{chat.name}</strong>
            {#if wa}{#if typingNow}<small style:color={WA.green}>{typingNow}</small>{/if}{:else}<small>{chat.appName}</small>{/if}</span>
        </span>
      {/if}
    {/snippet}
    {#snippet trailing()}
      <button class="more" aria-label={tr("Meer", "More")} onclick={(e) => (menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections: [[
        chat && (chat.unread > 0 || chat.waitsInApp)
          ? { label: tr("Markeer als gelezen", "Mark as read"), icon: "mail-open", onselect: () => mark(true) }
          : { label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => mark(false) },
      ]] })}><Ico name="ellipsis" size={20} /></button>
    {/snippet}
  </NavBar>

  <ConversationScroll version={[lines.length, lines[lines.length - 1]?.id, typing.length]} background={wa ? WA.wallpaper : undefined}>
    {#if !loaded}<div class="spinner"></div>{/if}
    <div class="lines">
      {#each lines as l, i (l.id)}
        {#if i === 0 || day(lines[i - 1].date) !== day(l.date)}<div class="day"><span>{dayLabel(l.date)}</span></div>{/if}
        {@const head = first(i)}
        <div class="line" class:mine={l.fromMe} class:head class:tailend={lastOfRun(i)}>
          {#if group && !l.fromMe}<span class="face">{#if head}<InboxAvatar name={l.sender} size={28} badge={false} />{/if}</span>{/if}
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <div class="bubble" class:emoji={emojiOnly(l.text) && !l.quoteText && !l.attachment} class:tail={head} class:join={!lastOfRun(i)}
            onpointerdown={(e) => hold(e, l)} onpointermove={moved} onpointerup={release} onpointerleave={release} onpointercancel={release} oncontextmenu={(e) => e.preventDefault()}>
            {#if head && group && !l.fromMe && l.sender}<span class="sender" style:color={personTint(l.sender)}>{l.sender}</span>{/if}
            {#if l.quoteText}<span class="quote" class:me={l.quoteSender === tr("Jij", "You")}><strong>{l.quoteSender ?? ""}</strong><span>{l.quoteText}</span></span>{/if}
            {#if l.attachment}<span class="file"><Ico name="paperclip" size={13} />{l.attachment}</span>{/if}
            <span class="body">
              {#if l.text}<span class="words">{l.text}</span>{/if}
              <span class="stamp">{time(l.date)}{#if l.fromMe && l.ticks}<TicksMark ticks={l.ticks} read={wa ? WA.readTick : "var(--blue)"} quiet={wa ? WA.stampOnMine : "var(--chat-stamp)"} />{/if}</span>
            </span>
            {#if l.reactions.length}<span class="reactions">{l.reactions.slice(0, 3).join(" ")}</span>{/if}
          </div>
        </div>
      {/each}
      {#if typing.length && !wa}
        <div class="line head"><div class="bubble tail typingbubble"><span class="dots"><i></i><i></i><i></i></span>{typingNow}</div></div>
      {/if}
    </div>
  </ConversationScroll>

  {#if chat?.canSend}
    <div class="dock" style:background={wa ? `linear-gradient(transparent, ${WA.wallpaper} 30%)` : undefined}>
      {#if replyTo}
        <div class="replybar">
          <span class="rbar" style:background={replyTo.fromMe ? "var(--mint)" : "var(--blue)"}></span>
          <span class="rtext"><strong style:color={replyTo.fromMe ? "var(--mint)" : "var(--blue)"}>{replyTo.fromMe ? tr("Jij", "You") : replyTo.sender || chat.name}</strong><span>{replyTo.text || replyTo.attachment}</span></span>
          <button class="rclose" aria-label={tr("Annuleer antwoord", "Cancel reply")} onclick={() => (replyTo = null)}><Ico name="x" size={12} stroke={3} /></button>
        </div>
      {/if}
      {#if wa}
        <div class="wacomposer">
          <div class="pill"><textarea rows="1" bind:value={text} placeholder={tr("Bericht", "Message")}></textarea></div>
          {#if text.trim()}<button class="wasend" aria-label={tr("Verstuur", "Send")} disabled={sending} onclick={() => send(text.trim())}><Ico name="send" size={18} fill="currentColor" /></button>{/if}
        </div>
      {:else}
        <SessionComposer bind:value={text} placeholder={tr("Bericht", "Message")} onsend={send} {sending} />
      {/if}
    </div>
  {:else if loaded && chat}
    <div class="dock">
      <div class="readonly"><Ico name="info" size={13} /><span><span>{tr("Nook kan deze chat alleen lezen. Beantwoord hem in {app}.", "Nook can only read this chat. Answer it in {app}.", { app: chat.appName })}</span>
        <small>{tr("Koppel {app} in Nook › Instellingen › Chats op je Mac om vanaf je telefoon te antwoorden.", "To answer from your phone, link {app} in Nook › Settings › Chats on your Mac.", { app: chat.appName })}</small></span></div>
    </div>
  {/if}
</div>
{#if menu}<Menu sections={menu.sections} anchor={menu.anchor} onclose={() => (menu = null)} />{/if}

<style>
  .chat { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .who { display: flex; align-items: center; gap: 8px; min-width: 0; max-width: 260px; }
  .t { display: flex; flex-direction: column; min-width: 0; }
  .t strong { font: var(--pt-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .wa .t strong { font: 600 17px var(--font); }
  .t small { font: var(--pt-caption); color: var(--text3); }
  .wa .t small { font: 400 12.5px var(--font); }
  .more { width: 44px; height: 44px; display: inline-flex; align-items: center; justify-content: center; color: var(--paper) !important; }
  .spinner { margin: 40px auto; width: 24px; height: 24px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .lines { display: flex; flex-direction: column; gap: 2px; }
  .day { display: flex; justify-content: center; padding: 16px 0 8px; }
  .day span { padding: 4px 12px; border-radius: 8px; background: var(--chat-theirs); font: 600 12px var(--font); color: var(--text-strong); }
  .wa .day span { border-radius: 999px; background: #182229; color: #8696a0; font: 500 12.5px var(--font); }
  .line { display: flex; align-items: flex-end; gap: 6px; padding-right: 48px; }
  .line.mine { justify-content: flex-end; padding: 0 0 0 48px; }
  .line.head { padding-top: 6px; }
  .line.tailend { padding-bottom: 4px; }
  .face { width: 28px; flex: none; }
  .bubble { position: relative; max-width: 100%; display: flex; flex-direction: column; gap: 2px; padding: 6px 10px; border-radius: 10px; background: var(--chat-theirs); color: var(--paper); -webkit-touch-callout: none; user-select: none; }
  .mine .bubble { background: var(--chat-mine); }
  .wa .bubble { background: #1f2c34; color: #e9edef; border-radius: 9px; }
  .wa .mine .bubble { background: #005c4b; }
  .bubble.tail { border-top-left-radius: 0; }
  .mine .bubble.tail { border-top-left-radius: 10px; border-top-right-radius: 0; }
  .bubble.tail::before { content: ""; position: absolute; top: 0; left: -7px; width: 7px; height: 11px; background: inherit; clip-path: polygon(100% 0, 0 0, 100% 100%); }
  .mine .bubble.tail::before { left: auto; right: -7px; clip-path: polygon(0 0, 100% 0, 0 100%); }
  .bubble.join { border-bottom-left-radius: 4px; }
  .mine .bubble.join { border-bottom-left-radius: 10px; border-bottom-right-radius: 4px; }
  .bubble.emoji { background: transparent !important; padding: 0; }
  .bubble.emoji::before { display: none; }
  .bubble.emoji .words { font-size: 40px; line-height: 1.1; }
  .sender { font: var(--pt-label); }
  .quote { display: flex; flex-direction: column; padding: 4px 8px 4px 12px; border-radius: 6px; background: rgba(255, 255, 255, 0.05); border-left: 3px solid var(--blue); }
  .quote.me { border-left-color: var(--mint); }
  .quote strong { font: var(--pt-label); color: var(--blue); }
  .quote.me strong { color: var(--mint); }
  .quote span { font: var(--pt-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .file { display: flex; align-items: center; gap: 6px; font: var(--pt-label); color: var(--text-strong); }
  .body { display: flex; flex-wrap: wrap; align-items: last baseline; justify-content: flex-end; gap: 0 8px; }
  .words { flex: 1 1 auto; font: var(--pt-body); white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; }
  .wa .words { font: 400 16px/1.35 var(--font); }
  .stamp { display: inline-flex; align-items: center; gap: 3px; font: var(--pt-caption); color: var(--chat-stamp); font-variant-numeric: tabular-nums; margin-left: auto; }
  .wa .stamp { font: 400 11.5px var(--font); color: #8696a0; }
  .wa .mine .stamp { color: #8db5ac; }
  .reactions { position: absolute; bottom: -12px; left: 13px; padding: 1px 6px; border-radius: 999px; background: var(--chat-theirs); box-shadow: 0 0 0 2px var(--canvas); font-size: 14px; }
  .mine .reactions { left: auto; right: 13px; }
  .line:has(.reactions) { margin-bottom: 12px; }
  .typingbubble { flex-direction: row; align-items: center; gap: 6px; padding: 8px 12px; font: var(--pt-detail); color: var(--text2); }
  .dots { display: inline-flex; gap: 3px; }
  .dots i { width: 6px; height: 6px; border-radius: 50%; background: var(--text2); opacity: 0.35; animation: dot 0.9s infinite steps(1); }
  .dots i:nth-child(2) { animation-delay: 0.3s; }
  .dots i:nth-child(3) { animation-delay: 0.6s; }
  @keyframes dot { 0% { opacity: 1; } 33% { opacity: 0.35; } }
  .dock { padding: 8px 12px; background: linear-gradient(transparent, var(--canvas) 30%); }
  .replybar { display: flex; align-items: center; gap: 8px; padding: 8px 12px 24px; margin: 0 6px -16px; background: var(--field); border: 1px solid var(--field-stroke); border-radius: 16px 16px 0 0; animation: rise 240ms ease-out; }
  .rbar { width: 3px; align-self: stretch; border-radius: 999px; }
  .rtext { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .rtext strong { font: var(--pt-label); }
  .rtext span { font: var(--pt-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .rclose { width: 28px; height: 28px; display: inline-flex; align-items: center; justify-content: center; color: var(--text3) !important; }
  .wacomposer { display: flex; align-items: flex-end; gap: 6px; padding: 6px; }
  .pill { flex: 1; display: flex; padding: 4px 6px 4px 16px; border-radius: 22px; background: #1f2c34; min-height: 36px; align-items: center; }
  .pill textarea { flex: 1; resize: none; font: 400 17px var(--font) !important; color: #e9edef !important; caret-color: #00a884; field-sizing: content; max-height: 140px; padding: 4px 0 !important; }
  .wasend { width: 44px; height: 44px; border-radius: 50%; background: #00a884 !important; color: #0b141a !important; display: inline-flex; align-items: center; justify-content: center; flex: none; animation: grow 200ms ease-out; }
  .readonly { display: flex; align-items: baseline; gap: 6px; padding: 12px; background: var(--field); border-radius: 12px; font: var(--pt-detail); color: var(--text2); }
  .readonly span { display: flex; flex-direction: column; gap: 2px; }
  .readonly small { font: var(--pt-detail); color: var(--text3); }
  @keyframes rise { from { opacity: 0; transform: translateY(8px); } }
  @keyframes grow { from { transform: scale(0.4); } }
</style>
