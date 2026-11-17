<script lang="ts">
  // One chat as the iPhone shows it (`InboxChatView`): bubbles in runs (the first of a run with a tail and, in a group,
  // the sender), a day divider where a day starts, quotes, reactions and ticks. A WhatsApp chat wears WhatsApp's colors.
  // A chat the computer can write in is answered here, also as a reply to one of its messages (touch and hold it); any
  // other says how to answer it.
  // A computer with `chatActions` gives what the Mac's chat does: quick reactions, editing, forwarding and deleting a
  // message, polls, photos (`inboxMedia`), older messages (`inboxOlder`), pictures and files with your words, and the
  // chat's info, each where the chat's app takes it (`abilities`).
  import { onDestroy, onMount, untrack } from "svelte";
  import {
    abilities, companion, followsLive, has, mediaWord, mergeInboxLines, personTint, pollChoice, pollVoting, prependInboxLines, typingText, writingWaits,
    Feature, MAX_FILE_BYTES, QUICK_REACTIONS,
    type ClientView, type CompanionFile, type CompanionResponse, type InboxAction, type InboxChatDigest, type InboxLine, type InboxTypist,
  } from "../../lib/companion";
  import { base64Bytes } from "../../lib/images";
  import { act, chatMenu, messageMenu, type ChatConfirm } from "./chat-actions";
  import { media } from "./inbox-media.svelte";
  import Dialog from "./ui/Dialog.svelte";
  import PhotoButton from "./ui/PhotoButton.svelte";
  import ImageTray from "./ui/ImageTray.svelte";
  import ChatInfo from "./ChatInfo.svelte";
  import ForwardPicker from "./ForwardPicker.svelte";
  import { locale, tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NavBar from "./ui/NavBar.svelte";
  import Ico from "./ui/Ico.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import TicksMark from "./ui/TicksMark.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import Menu, { type MenuItem, type MenuReactions } from "./ui/Menu.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";
  import { WA } from "./ui/whatsapp";
  import Sheet from "./ui/Sheet.svelte";
  import MessageInfo from "./MessageInfo.svelte";
  import OfflineStrip from "./ui/OfflineStrip.svelte";
  import OfflineNote from "./ui/OfflineNote.svelte";
  import { activeMac, cacheFor, kept, recordInboxLines, saveSoon } from "../../lib/companion-cache";

  let { view, id, chat, chats = [], onback, took }: {
    view: ClientView; id: string; chat: InboxChatDigest | null; chats?: InboxChatDigest[]; onback: () => void; took: (v: ClientView) => void;
  } = $props();

  // The chat as the phone kept it (`companion-cache.ts`), until the computer answers.
  let lines = $state<InboxLine[]>(untrack(() => kept(cacheFor(activeMac(view))?.inboxLines ?? [], id) ?? []));
  const offline = $derived(view.phase === "offline");
  // Your messages that wait on the phone for the computer, dimmed, until it takes them.
  const queued = $derived((view.outbox ?? []).filter((q) => q.op === "inboxSend" && q.item === id));
  $effect(() => {
    const mac = activeMac(view);
    const cache = cacheFor(mac);
    if (!cache || offline || !loaded || !lines.length) return;
    if (recordInboxLines(cache, id, lines, Date.now() / 1000)) saveSoon(mac);
  });
  let typing = $state<InboxTypist[]>([]);
  let loaded = $state(false);
  let text = $state("");
  let replyTo = $state<InboxLine | null>(null);
  let sending = $state(false);
  let menu = $state<{ anchor: DOMRect; sections: MenuItem[][]; reactions?: MenuReactions } | null>(null);
  let info = $state<InboxLine | null>(null);
  const wa = $derived(chat?.app === "whatsapp");
  const live = $derived(followsLive(view, Feature.liveChats));
  const group = $derived(chat?.group ?? lines.some((l) => !l.fromMe && l.sender));
  const rich = $derived(has(view, Feature.chatActions));
  const can = $derived(abilities(chat));
  // The app may have older messages than the phone has: "Load older messages" at the top (`inboxOlder`).
  let more = $state(false);
  let older = $state(false);
  let editing = $state<InboxLine | null>(null);
  let forwarding = $state<InboxLine | null>(null);
  let confirming = $state<ChatConfirm | null>(null);
  let chatInfo = $state(false);
  let enlarged = $state<string | null>(null);
  let images = $state<string[]>([]);
  let files = $state<CompanionFile[]>([]);
  let filePicker = $state<HTMLInputElement | null>(null);

  /** The newest messages again: what you paged back to stays before them (`InboxPaging.merge`). A computer without
   * `chatActions` has no older pages, so its answer is the chat whole. */
  function take(r: Pick<CompanionResponse, "inboxLines" | "inboxMore"> | null | undefined) {
    if (!r) return;
    if (r.inboxLines) lines = untrack(() => rich) ? mergeInboxLines(r.inboxLines, lines) : r.inboxLines;
    if (r.inboxMore !== undefined) more = r.inboxMore;
  }

  async function load() {
    if (document.visibilityState !== "visible") return;
    const r = await companion.call(untrack(() => live) ? { op: "watchChat", item: id } : { op: "inboxChat", item: id });
    take(r.response);
    typing = r.response?.inboxTyping ?? [];
    loaded = true;
    if (!r.response) took(r.view);
  }
  async function loadOlder() {
    const first = lines[0];
    if (!first || older) return;
    older = true;
    const r = await companion.call({ op: "inboxOlder", item: id, text: first.id });
    older = false;
    if (!r.response) return took(r.view);
    lines = prependInboxLines(r.response.inboxLines ?? [], r.response.inboxBefore ?? first.id, lines);
    more = r.response.inboxMore ?? false;
  }
  $effect(() => { if (rich) void media.fetch(id, lines); });
  onMount(() => {
    load();
    const un = companion.onLive((r) => {
      if (r.inboxChat !== id) return;
      take(r);
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
    if (editing) return edit(editing, words);
    sending = true;
    const r = await companion.call({
      op: "inboxSend", item: id, text: words, replyTo: replyTo?.id,
      images: images.length ? images.map((jpeg) => ({ jpeg })) : undefined,
      attachments: files.length ? files : undefined,
    });
    sending = false;
    took(r.view);
    if (!r.response) return;
    haptic("success");
    text = "";
    replyTo = null;
    images = [];
    files = [];
    if (r.response.message === "outbox") return;
    take(r.response);
  }

  /** One action in this chat (`inboxAct`); the answer has the messages as they are after it. */
  async function run(action: InboxAction) {
    const r = await act(id, action);
    took(r.view);
    if (!r.response) return;
    haptic("success");
    if (action.kind === "remove" || action.kind === "deleteChat" || action.kind === "archive") return onback();
    take(r.response);
  }
  async function edit(line: InboxLine, words: string) {
    sending = true;
    const r = await act(id, { kind: "edit", message: line.id, text: words });
    sending = false;
    took(r.view);
    if (!r.response) return;
    editing = null;
    text = "";
    take(r.response);
  }
  function startEdit(line: InboxLine) {
    editing = line;
    replyTo = null;
    text = line.text;
  }
  function cancelEdit() {
    editing = null;
    text = "";
  }
  /** A tap on a poll's option: your vote shows at once, then the app confirms it. */
  function vote(line: InboxLine, option: string) {
    if (!line.poll || !can.has("vote") || line.local) return;
    const choice = pollChoice(line.poll, option);
    const poll = pollVoting(line.poll, choice);
    lines = lines.map((l) => (l.id === line.id ? { ...l, poll } : l));
    haptic();
    void run({ kind: "vote", message: line.id, choices: choice });
  }
  function forward(targets: string[]) {
    const line = forwarding;
    forwarding = null;
    if (line) void run({ kind: "forward", message: line.id, targets });
  }
  const tooLarge = () => took({ ...view, notice: tr("Die foto kon niet klein genoeg worden gemaakt.", "That picture could not be made small enough.") });
  async function pickFile() {
    const file = filePicker?.files?.[0];
    if (filePicker) filePicker.value = "";
    if (!file) return;
    const data = await new Promise<string | null>((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
      reader.onerror = () => resolve(null);
      reader.readAsDataURL(file);
    });
    if (!data || base64Bytes(data) > MAX_FILE_BYTES) {
      took({ ...view, notice: tr("Een bestand van de telefoon mag hoogstens 150 KB zijn. Stuur grotere bestanden vanuit de app van de chat zelf.", "A file from the phone can be at most 150 KB. Send larger files from the chat's own app.") });
      return;
    }
    files = [{ name: file.name, data }];
  }
  const duration = (s: number) => `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, "0")}`;
  const mediaIcon = (m: string) => (m === "photo" || m === "gif" || m === "sticker" ? "file-image" : m === "video" ? "file-video" : m === "audio" || m === "voice" ? "file-audio" : "file");

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
      if (rich && chat) {
        if (line.notice) return;
        const react = can.has("react") && !line.local && !line.deleted;
        menu = {
          anchor: el.getBoundingClientRect(),
          sections: messageMenu(chat, line, run, (c) => (confirming = c), {
            reply: () => { if (editing) cancelEdit(); replyTo = line; },
            edit: () => startEdit(line),
            forward: () => (forwarding = line),
            info: () => (info = line),
          }),
          reactions: react ? { emoji: QUICK_REACTIONS, mine: line.myReactions ?? [], onpick: (emoji) => void run({ kind: "react", message: line.id, emoji }) } : undefined,
        };
        return;
      }
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
        <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
        <span class="who" class:left={wa} class:tappable={rich && chat.hasInfo} onclick={() => { if (rich && chat?.hasInfo) chatInfo = true; }}>
          <InboxAvatar id={chat.id} name={chat.name} app={chat.app} size={wa ? 36 : 30} badge={!wa} />
          <span class="t"><strong style:color={wa ? WA.text : undefined}>{chat.name}</strong>
            {#if wa}{#if typingNow}<small style:color={WA.green}>{typingNow}</small>{/if}{:else}<small>{chat.appName}</small>{/if}</span>
        </span>
      {/if}
    {/snippet}
    {#snippet trailing()}
      <button class="more" aria-label={tr("Meer", "More")} onclick={(e) => (menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections: rich && chat ? chatMenu(chat, run, (c) => (confirming = c), () => (chatInfo = true)) : [[
        chat && (chat.unread > 0 || chat.waitsInApp)
          ? { label: tr("Markeer als gelezen", "Mark as read"), icon: "mail-open", onselect: () => mark(true) }
          : { label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => mark(false) },
      ]] })}><Ico name="ellipsis" size={20} /></button>
    {/snippet}
  </NavBar>

  <ConversationScroll version={[lines.length, lines[lines.length - 1]?.id, typing.length]} background={wa ? WA.wallpaper : undefined}>
    {#if offline && !lines.length && !queued.length}
      <OfflineNote>{tr("Deze chat staat nog niet op deze telefoon. Hij opent zodra je Mac verbonden is.", "This chat is not kept on this phone yet. It opens once your Mac is connected.")}</OfflineNote>
    {:else if !loaded && !lines.length}<div class="spinner"></div>{/if}
    <div class="lines">
      {#if rich && more && lines.length}
        <button class="older" disabled={older} onclick={loadOlder}>{#if older}<span class="minispin"></span>{/if}{tr("Oudere berichten", "Older messages")}</button>
      {/if}
      {#each lines as l, i (l.id)}
        {#if i === 0 || day(lines[i - 1].date) !== day(l.date)}<div class="day"><span>{dayLabel(l.date)}</span></div>{/if}
        {@const head = first(i)}
        {#if l.notice}
        <div class="notice"><span>{l.text}</span></div>
        {:else}
        {@const photo = rich ? media.photo(l) : undefined}
        <div class="line" class:mine={l.fromMe} class:head class:tailend={lastOfRun(i)}>
          {#if group && !l.fromMe}<span class="face">{#if head}<InboxAvatar name={l.sender} size={28} badge={false} />{/if}</span>{/if}
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <div class="bubble" class:emoji={emojiOnly(l.text) && !l.quoteText && !l.attachment && !photo && !l.poll} class:local={l.local} class:tail={head} class:join={!lastOfRun(i)}
            onpointerdown={(e) => hold(e, l)} onpointermove={moved} onpointerup={release} onpointerleave={release} onpointercancel={release} oncontextmenu={(e) => e.preventDefault()}>
            {#if head && group && !l.fromMe && l.sender}<span class="sender" style:color={personTint(l.sender)}>{l.sender}</span>{/if}
            {#if l.quoteText}<span class="quote" class:me={l.quoteSender === tr("Jij", "You")}><strong>{l.quoteSender ?? ""}</strong><span>{l.quoteText}</span></span>{/if}
            {#if photo}
              <button class="photo" aria-label={tr("Vergroot foto", "Enlarge photo")} onclick={() => (enlarged = photo)}><img src={photo} alt="" />{#if l.media === "video"}<span class="play"><Ico name="circle-play" size={34} /></span>{/if}</button>
            {:else if rich && l.media && !l.deleted && (l.media !== "file" || !l.attachment)}
              <span class="file"><Ico name={mediaIcon(l.media)} size={13} />{mediaWord(l.media)}{#if l.seconds} · {duration(l.seconds)}{/if}</span>
            {/if}
            {#if l.attachment && !l.deleted && !photo}<span class="file"><Ico name="paperclip" size={13} />{l.attachment}</span>{/if}
            {#if l.poll && !l.deleted}
              {@const total = l.poll.options.reduce((n, o) => n + o.votes, 0)}
              <span class="poll">
                <strong>{l.poll.question}</strong>
                <small>{!can.has("vote") ? tr("Stem in de app zelf.", "Vote in its own app.") : l.poll.multiple ? tr("Kies er een of meer", "Choose one or more") : tr("Kies er een", "Choose one")}</small>
                {#each l.poll.options as o (o.text)}
                  <button class="option" class:chosen={o.chosen} disabled={!can.has("vote") || l.local} onclick={() => vote(l, o.text)}>
                    <span class="box">{#if o.chosen}<Ico name="check" size={11} stroke={3} />{/if}</span>
                    <span class="otext"><span class="orow"><span>{o.text}</span>{#if l.poll.counted}<small>{o.votes}</small>{/if}</span>
                      {#if l.poll.counted}<span class="meter"><i style:width="{total ? (o.votes / total) * 100 : 0}%"></i></span>{/if}</span>
                  </button>
                {/each}
              </span>
            {/if}
            <span class="body">
              {#if l.deleted}<span class="words gone"><Ico name="circle-x" size={13} />{l.fromMe ? tr("Je hebt dit bericht verwijderd", "You deleted this message") : tr("Dit bericht is verwijderd", "This message was deleted")}</span>
              {:else if l.text && !(l.poll && l.text === l.poll.question)}<span class="words">{l.text}</span>{/if}
              <span class="stamp">{#if l.edited && !l.deleted}<span class="edited">{tr("Bewerkt", "Edited")}</span>{/if}{#if l.local}<Ico name="clock" size={10} />{/if}{time(l.date)}{#if l.fromMe && l.ticks}{#if l.readers?.length}<button class="ticks" aria-label={tr("Berichtinfo", "Message info")} onclick={() => (info = l)}><TicksMark ticks={l.ticks} read={wa ? WA.readTick : "var(--blue)"} quiet={wa ? WA.stampOnMine : "var(--chat-stamp)"} /></button>{:else}<TicksMark ticks={l.ticks} read={wa ? WA.readTick : "var(--blue)"} quiet={wa ? WA.stampOnMine : "var(--chat-stamp)"} />{/if}{/if}</span>
            </span>
            {#if l.reactions.length}<span class="reactions">{l.reactions.slice(0, 3).join(" ")}</span>{/if}
          </div>
        </div>
        {/if}
      {/each}
      {#each queued as q (q.id)}
        <div class="line mine head tailend waiting"><div class="bubble tail"><span class="body"><span class="words">{q.text}</span></span></div></div>
        <span class="notsent"><Ico name="clock" size={11} />{tr("Nog niet verstuurd · wacht op je Mac", "Not sent yet · waiting for your Mac")}</span>
      {/each}
      {#if typing.length && !wa}
        <div class="line head"><div class="bubble tail typingbubble"><span class="dots"><i></i><i></i><i></i></span>{typingNow}</div></div>
      {/if}
    </div>
  </ConversationScroll>

  {#if chat?.canSend}
    <div class="dock" style:background={wa ? `linear-gradient(transparent, ${WA.wallpaper} 30%)` : undefined}>
      <OfflineStrip {view} />
      {#if editing}
        <div class="replybar">
          <span class="rbar" style:background="var(--amber)"></span>
          <span class="rtext"><strong style:color="var(--amber)">{tr("Bericht wijzigen", "Edit message")}</strong><span>{editing.text}</span></span>
          <button class="rclose" aria-label={tr("Stop met wijzigen", "Cancel editing")} onclick={cancelEdit}><Ico name="x" size={12} stroke={3} /></button>
        </div>
      {:else if replyTo}
        <div class="replybar">
          <span class="rbar" style:background={replyTo.fromMe ? "var(--mint)" : "var(--blue)"}></span>
          <span class="rtext"><strong style:color={replyTo.fromMe ? "var(--mint)" : "var(--blue)"}>{replyTo.fromMe ? tr("Jij", "You") : replyTo.sender || chat.name}</strong><span>{replyTo.text || replyTo.attachment}</span></span>
          <button class="rclose" aria-label={tr("Annuleer antwoord", "Cancel reply")} onclick={() => (replyTo = null)}><Ico name="x" size={12} stroke={3} /></button>
        </div>
      {/if}
      {#if rich && !editing && (images.length || files.length)}
        <div class="attached">
          <ImageTray {images} onremove={(i) => (images = images.filter((_, j) => j !== i))} />
          {#each files as f, i (f.name + i)}
            <span class="filechip"><Ico name="file" size={13} /><span>{f.name}</span><button aria-label={tr("Bestand verwijderen", "Remove file")} onclick={() => (files = files.filter((_, j) => j !== i))}><Ico name="x" size={10} stroke={3} /></button></span>
          {/each}
        </div>
      {/if}
      {#snippet attach()}
        {#if rich && !editing && can.has("photo")}<PhotoButton count={images.length} onpick={(more) => (images = [...images, ...more])} ontoolarge={tooLarge} />{/if}
        {#if rich && !editing && can.has("file")}
          <button class="attach" aria-label={tr("Bestand toevoegen", "Attach a file")} disabled={files.length > 0} onclick={() => filePicker?.click()}><Ico name="paperclip" size={15} stroke={2.2} /></button>
          <input bind:this={filePicker} type="file" hidden onchange={pickFile} />
        {/if}
      {/snippet}
      {#if wa}
        <div class="wacomposer">
          {@render attach()}
          <div class="pill"><textarea rows="1" bind:value={text} placeholder={tr("Bericht", "Message")}></textarea></div>
          {#if text.trim() || (!editing && (images.length || files.length))}<button class="wasend" aria-label={tr("Verstuur", "Send")} disabled={sending || (offline && !writingWaits(view))} onclick={() => send(text.trim())}><Ico name="send" size={18} fill="currentColor" /></button>{/if}
        </div>
      {:else}
        <div class="withattach">
          {@render attach()}
          <div class="grow"><SessionComposer bind:value={text} placeholder={tr("Bericht", "Message")} onsend={send} {sending} canSend={!offline || writingWaits(view)} attached={!editing && (images.length > 0 || files.length > 0)} /></div>
        </div>
      {/if}
    </div>
  {:else if (loaded || offline) && chat}
    <div class="dock">
      <OfflineStrip {view} kind="reads" />
      <div class="readonly"><Ico name="info" size={13} /><span><span>{tr("Nook kan deze chat alleen lezen. Beantwoord hem in {app}.", "Nook can only read this chat. Answer it in {app}.", { app: chat.appName })}</span>
        <small>{tr("Koppel {app} in Nook › Instellingen › Chats op je Mac om vanaf je telefoon te antwoorden.", "To answer from your phone, link {app} in Nook › Settings › Chats on your Mac.", { app: chat.appName })}</small></span></div>
    </div>
  {/if}
</div>
{#if info}{@const l = info}<Sheet onclose={() => (info = null)}><MessageInfo line={l} onclose={() => (info = null)} /></Sheet>{/if}
{#if menu}<Menu sections={menu.sections} anchor={menu.anchor} reactions={menu.reactions} onclose={() => (menu = null)} />{/if}
{#if chatInfo && chat}{@const c = chat}<Sheet onclose={() => (chatInfo = false)}><ChatInfo chat={c} {took} onclose={() => (chatInfo = false)} /></Sheet>{/if}
{#if forwarding && chat}{@const l = forwarding}<Sheet onclose={() => (forwarding = null)}><ForwardPicker line={l} {chats} from={id} onsend={forward} onclose={() => (forwarding = null)} /></Sheet>{/if}
{#if confirming}{@const c = confirming}
  <Dialog title={c.title} message={c.message} onclose={() => (confirming = null)}
    buttons={[{ label: c.button, destructive: true, onselect: c.run }, { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} }]} />
{/if}
{#if enlarged}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="viewer" onclick={() => (enlarged = null)}>
    <img src={enlarged} alt="" />
    <button class="vclose" aria-label={tr("Sluit", "Close")} onclick={() => (enlarged = null)}><Ico name="x" size={16} stroke={2.6} /></button>
  </div>
{/if}

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
  .ticks { display: inline-flex; padding: 0 !important; }
  .reactions { position: absolute; bottom: -12px; left: 13px; padding: 1px 6px; border-radius: 999px; background: var(--chat-theirs); box-shadow: 0 0 0 2px var(--canvas); font-size: 14px; }
  .mine .reactions { left: auto; right: 13px; }
  .line:has(.reactions) { margin-bottom: 12px; }
  .typingbubble { flex-direction: row; align-items: center; gap: 6px; padding: 8px 12px; font: var(--pt-detail); color: var(--text2); }
  .dots { display: inline-flex; gap: 3px; }
  .dots i { width: 6px; height: 6px; border-radius: 50%; background: var(--text2); opacity: 0.35; animation: dot 0.9s infinite steps(1); }
  .dots i:nth-child(2) { animation-delay: 0.3s; }
  .dots i:nth-child(3) { animation-delay: 0.6s; }
  @keyframes dot { 0% { opacity: 1; } 33% { opacity: 0.35; } }
  .waiting { opacity: 0.6; }
  .notsent { display: flex; align-items: center; justify-content: flex-end; gap: 4px; padding: 2px 4px 6px; font: var(--pt-caption); color: var(--text3); }
  .wa .notsent { color: #8696a0; }
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
  .who.tappable { cursor: pointer; }
  .older { align-self: center; display: inline-flex; align-items: center; gap: 6px; margin: 8px 0; padding: 6px 12px !important; border-radius: 999px; background: var(--chat-theirs) !important; font: var(--pt-label) !important; color: var(--text2) !important; }
  .wa .older { background: #182229 !important; color: #8696a0 !important; }
  .minispin { width: 12px; height: 12px; border-radius: 50%; border: 2px solid var(--text3); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  .notice { display: flex; justify-content: center; padding: 6px 24px; }
  .notice span { padding: 4px 12px; border-radius: 8px; background: var(--chat-theirs); font: var(--pt-caption); color: var(--text2); text-align: center; }
  .wa .notice span { background: #182229; color: #8696a0; }
  .bubble.local { opacity: 0.7; }
  .photo { position: relative; display: block; padding: 0 !important; margin: -2px -6px 2px; border-radius: 8px; overflow: hidden; }
  .photo img { display: block; max-width: min(260px, 100%); max-height: 320px; object-fit: cover; }
  .play { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: #fff; }
  .poll { display: flex; flex-direction: column; gap: 6px; min-width: 220px; padding: 2px 0; }
  .poll strong { font: var(--pt-strong); }
  .poll > small { font: var(--pt-caption); color: var(--chat-stamp); }
  .option { display: flex; align-items: flex-start; gap: 8px; padding: 4px 0 !important; text-align: left; color: inherit !important; }
  .option:disabled { opacity: 1 !important; }
  .box { width: 18px; height: 18px; border-radius: 50%; border: 1.5px solid var(--chat-stamp); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .option.chosen .box { background: var(--mint); border-color: var(--mint); color: var(--canvas); }
  .otext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
  .orow { display: flex; justify-content: space-between; gap: 8px; font: var(--pt-body); }
  .orow small { font: var(--pt-caption); color: var(--chat-stamp); }
  .meter { height: 4px; border-radius: 2px; background: rgba(255, 255, 255, 0.12); overflow: hidden; }
  .meter i { display: block; height: 100%; background: var(--mint); }
  .words.gone { display: inline-flex; align-items: center; gap: 6px; font-style: italic; color: var(--text2); }
  .edited { margin-right: 4px; font-style: italic; }
  .attached { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 0 6px 6px; }
  .filechip { display: inline-flex; align-items: center; gap: 6px; max-width: 240px; padding: 6px 6px 6px 10px; border-radius: 10px; background: var(--field); font: var(--pt-detail); color: var(--text-strong); }
  .filechip span { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .filechip button { width: 22px; height: 22px; border-radius: 50%; background: var(--smoke) !important; display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .withattach { display: flex; align-items: flex-end; gap: 6px; }
  .withattach .grow { flex: 1; min-width: 0; }
  .attach { width: 34px; height: 34px; margin-bottom: 6px; border-radius: 50%; background: var(--smoke) !important; color: var(--text2) !important; display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .viewer { position: fixed; inset: 0; z-index: 80; background: rgba(0, 0, 0, 0.92); display: flex; align-items: center; justify-content: center; animation: fade 160ms ease-out; }
  .viewer img { max-width: 100%; max-height: 100%; object-fit: contain; }
  .vclose { position: absolute; top: calc(var(--safe-top, 0px) + 12px); right: 12px; width: 36px; height: 36px; border-radius: 50%; background: rgba(255, 255, 255, 0.14) !important; color: #fff !important; display: inline-flex; align-items: center; justify-content: center; }
  @keyframes fade { from { opacity: 0; } }
  @keyframes rise { from { opacity: 0; transform: translateY(8px); } }
  @keyframes grow { from { transform: scale(0.4); } }
</style>
