<script module lang="ts">
  // The screen that holds the live conversation now: an older one that closes after a newer one opened leaves it on.
  let watcher: symbol | null = null;
</script>

<script lang="ts">
  // A chat with Nook on your computer (`ChatView`): your words and Nook's answers as in a session, "Thinking…" with Nook's
  // face while it writes, and Ask Nook at the bottom, Stop while it writes. A plan, draft or chart waits on the computer.
  import { onDestroy, onMount, untrack } from "svelte";
  import {
    applyConversation, companion, CONVERSATION_STALL, Feature, followsLive, messageTime, resumePoint, writingWaits,
    has, type ChatDigest, type ChatLine, type ClientView, type CompanionResponse, type NookChatAction,
  } from "../../lib/companion";
  import { nookAct, nookMenu } from "./nook-chats";
  import type { ChatConfirm } from "./chat-actions";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import Dialog from "../../components/ui/Dialog.svelte";
  import PhotoButton from "./ui/PhotoButton.svelte";
  import ImageTray from "./ui/ImageTray.svelte";
  import { activeMac, cacheFor, kept, recordChatLines, saveSoon } from "../../lib/companion-cache";
  import OfflineStrip from "./ui/OfflineStrip.svelte";
  import OfflineNote from "./ui/OfflineNote.svelte";
  import MarkdownBody from "../../components/MarkdownBody.svelte";
  import { richContent } from "../../lib/rich";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NavBar from "./ui/NavBar.svelte";
  import NookMark from "./ui/NookMark.svelte";
  import PulseDot from "../../components/ui/PulseDot.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";

  let { view, id: initial, ask: question, onback, took }: {
    view: ClientView; id: string | null; ask?: string; onback: () => void; took: (v: ClientView) => void;
  } = $props();

  let id = $state<string | null>(untrack(() => initial));
  let title = $state("");
  // What the phone kept of this chat (`companion-cache.ts`) until the computer answers.
  const cache = $derived(cacheFor(activeMac(view)));
  let lines = $state<ChatLine[]>(untrack(() => (initial && kept(cacheFor(activeMac(view))?.chatLines ?? [], initial)) || []));
  const offline = $derived(view.phase === "offline");
  $effect(() => {
    if (!cache || !id || offline || !lines.length) return;
    if (recordChatLines(cache, id, lines, Date.now() / 1000)) saveSoon(activeMac(view));
  });
  let text = $state("");
  let sending = $state(false);
  const busy = $derived(sending || lines.some((l) => l.streaming));
  const last = $derived(lines[lines.length - 1]);
  const queued = $derived((view.outbox ?? []).filter((q) => q.op === "ask" && (q.conversation ?? null) === id));
  const thinking = $derived(sending || (last?.fromNook && last.streaming && !last.text));

  // With a computer that keeps a connection open, Nook's answer comes by itself as it writes (`watchConversation`):
  // only its new words travel, a reconnect fetches only what came after the last finished message, and a missed update
  // asks for the conversation again. Without one, this screen asks.
  const live = $derived(followsLive(view, Feature.liveConversation) && view.phase === "connected");
  const me = Symbol("NookChat");
  let heard = Date.now();

  /** Takes an answer or a live update; false when it does not build on what this screen has. */
  function take(r: Pick<CompanionResponse, "messages" | "messagesAfter" | "messageAppend">): boolean {
    const next = applyConversation(lines, r);
    if (!next) return false;
    if (next !== lines) lines = next;
    heard = Date.now();
    return true;
  }

  async function load(resume = true) {
    if (!id || document.visibilityState !== "visible" || untrack(() => offline)) return;
    if (untrack(() => live)) {
      watcher = me;
      const conversation = id;
      const r = await companion.call({ op: "watchConversation", conversation, item: resume ? resumePoint(lines) : undefined });
      if (r.response && conversation === id && !take(r.response) && resume) await load(false);
      return;
    }
    const r = await companion.call({ op: "chat", conversation: id });
    if (r.response?.messages) lines = r.response.messages;
  }
  async function loadTitle() {
    const r = await companion.call({ op: "chats" });
    digest = r.response?.conversations?.find((c) => c.id === id) ?? null;
    title = digest?.title ?? "";
  }

  // As on the Mac's Nook tab (`nookChats`): the conversation's menu in the bar, questions that wait in line while Nook
  // answers, and pictures with a question.
  const likeTheMac = $derived(has(view, Feature.nookChats));
  let digest = $state<ChatDigest | null>(null);
  let images = $state<string[]>([]);
  let menu = $state<DOMRect | null>(null);
  let confirming = $state<ChatConfirm | null>(null);
  let renaming = $state(false);
  let newName = $state("");
  // Follows the list live: the title, the flags and the questions in line.
  onMount(() => {
    const un = companion.onLive((r) => {
      const d = r.conversations?.find((c) => c.id === id);
      if (d) { digest = d; title = d.title; }
    });
    return () => { un.then((f) => f()); };
  });
  async function run(action: NookChatAction) {
    if (!id) return;
    const r = await nookAct(id, action);
    took(r.view);
    if (!r.response) return;
    if (action.kind === "delete") { onback(); return; }
    const d = r.response.conversations?.find((c) => c.id === id);
    if (d) { digest = d; title = d.title; }
    if (r.response.messages) lines = r.response.messages;
  }
  const menuSections = $derived<MenuItem[][]>(digest ? nookMenu(digest, run, (c) => (confirming = c), () => { renaming = true; newName = title; }, lines.some((l) => !l.fromNook)) : []);
  const tooLarge = () => took({ ...view, notice: tr("Die foto kon niet klein genoeg worden gemaakt.", "That picture could not be made small enough.") });

  // Live: watch this conversation (again) once the connection is there or another conversation opened here.
  $effect(() => {
    if (id && live) untrack(() => load());
  });
  onMount(() => {
    const un = companion.onLive((r) => {
      if (!id || r.messagesConversation !== id) return;
      if (!take(r)) load(false);
    });
    return () => { un.then((f) => f()); };
  });
  onDestroy(() => {
    if (watcher !== me) return;
    watcher = null;
    if (untrack(() => live)) companion.call({ op: "watchConversation" });
  });

  // Without a live connection: ask every 1.5 seconds while Nook writes, otherwise every 6. Live, only check that an
  // answer being written did not get stuck on a bad connection.
  $effect(() => {
    if (!id) return;
    if (live) {
      const timer = setInterval(() => {
        if (untrack(() => last?.streaming) && Date.now() - heard > CONVERSATION_STALL) load();
      }, 2000);
      return () => clearInterval(timer);
    }
    const timer = setInterval(load, busy ? 1500 : 6000);
    return () => clearInterval(timer);
  });

  async function send(words: string) {
    if (sending) return;
    sending = true;
    haptic();
    const pictures = likeTheMac && images.length ? images.map((jpeg) => ({ jpeg })) : undefined;
    const r = await companion.call({ op: "ask", conversation: id ?? undefined, text: words, images: pictures });
    sending = false;
    took(r.view);
    if (!r.response) return;
    text = "";
    images = [];
    // Waits in line on the computer: the list shows it under the answer.
    if (r.response.message === "queued") loadTitle();
    if (r.response.created) id = r.response.created;
    if (r.response.messages) lines = r.response.messages;
    // Live, the new conversation is watched by the effect above; otherwise ask for it.
    else if (!live) load();
    if (!title) loadTitle();
  }

  async function stop() {
    if (!id) return;
    const r = await companion.call({ op: "chatStop", conversation: id });
    took(r.view);
    if (r.response?.messages) lines = r.response.messages;
  }

  onMount(() => {
    if (initial) { if (!untrack(() => live)) load(); loadTitle(); }
    else if (question) send(question);
  });
</script>

<div class="chat">
  <NavBar onback={onback}>
    {#snippet center()}<span class="t"><strong>{title || tr("Nieuwe chat", "New chat")}</strong><small>Nook</small></span>{/snippet}
    {#snippet trailing()}{#if likeTheMac && digest}<button class="more press" aria-label={tr("Meer acties", "More actions")} onclick={(e) => (menu = (e.currentTarget as HTMLElement).getBoundingClientRect())}><Ico name="ellipsis" size={18} stroke={2.4} /></button>{/if}{/snippet}
  </NavBar>
  <ConversationScroll version={[lines.length, last?.text.length, last?.status, sending]}>
    <div class="lines">
      {#if offline && id && !lines.length && !queued.length}
        <OfflineNote>{tr("Deze chat staat nog niet op deze telefoon. Hij opent zodra je Mac verbonden is.", "This chat is not kept on this phone yet. It opens once your Mac is connected.")}</OfflineNote>
      {/if}
      {#each lines as l (l.id)}
        {#if !l.fromNook}
          <div class="user"><div class="bubble">{l.text}</div><span class="time">{messageTime(l.date)}</span></div>
        {:else if l.text}
          <div class="answer" class:failed={l.failed}>
            <div class="markdown" use:richContent={l.text}><MarkdownBody text={l.text} html /></div>
            {#if !l.streaming}<span class="time">{messageTime(l.date)}</span>{/if}
            {#if l.onMac}<div class="onmac"><span style:color="var(--amber)"><Ico name="laptop" size={13} /></span>{tr("Nook maakte een plan, concept of grafiek: bekijk het op je Mac.", "Nook made a plan, draft or chart: see it on your Mac.")}</div>{/if}
          </div>
        {/if}
      {/each}
      {#each queued as q (q.id)}
        <div class="user waiting"><div class="bubble">{q.text}</div><span class="time"><Ico name="clock" size={11} /> {tr("Nog niet verstuurd · wacht op je Mac", "Not sent yet · waiting for your Mac")}</span></div>
      {/each}
      {#if digest?.queued?.length}
        {#each digest.queued as q, i (i)}
          <div class="user waiting"><div class="bubble">{q}</div></div>
        {/each}
        <span class="time inline"><Ico name="clock" size={11} /> {tr("Wacht op dit antwoord", "Waits for this answer")}</span>
      {/if}
      {#if thinking}
        <div class="thinking"><NookMark size={22} /><span>{last?.status || tr("Aan het denken…", "Thinking…")}</span><PulseDot size={5} color="var(--text2)" /></div>
      {/if}
    </div>
  </ConversationScroll>
  <div class="dock">
    <OfflineStrip {view} />
    {#if likeTheMac}<ImageTray {images} onremove={(i) => (images = images.filter((_, j) => j !== i))} />{/if}
    <div class="withattach">
      {#if likeTheMac}<PhotoButton count={images.length} onpick={(more) => (images = [...images, ...more])} ontoolarge={tooLarge} />{/if}
      <div class="grow"><SessionComposer bind:value={text} placeholder={tr("Vraag Nook", "Ask Nook")} onsend={send} onstop={busy ? stop : undefined} canSend={!offline || writingWaits(view)} attached={images.length > 0} /></div>
    </div>
  </div>
</div>

{#if menu}<Menu sections={menuSections} anchor={menu} title={title} onclose={() => (menu = null)} />{/if}
{#if confirming}{@const c = confirming}
  <Dialog title={c.title} message={c.message} onclose={() => (confirming = null)}
    buttons={[{ label: c.button, destructive: true, onselect: c.run }, { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} }]} />
{/if}
{#if renaming}
  <Dialog title={tr("Hernoem gesprek", "Rename conversation")} bind:field={newName} placeholder={tr("Naam", "Name")} onclose={() => (renaming = false)}
    buttons={[{ label: tr("Annuleer", "Cancel"), onselect: () => {} }, { label: tr("Hernoem", "Rename"), bold: true, onselect: () => {
      const name = newName.trim().slice(0, 80);
      if (name && name !== title) run({ kind: "rename", text: name });
    } }]} />
{/if}

<style>
  .more { width: 44px; height: 44px; display: inline-flex; align-items: center; justify-content: center; color: var(--text2); }
  .withattach { display: flex; align-items: flex-end; gap: 8px; }
  .grow { flex: 1; min-width: 0; }
  .inline { align-self: flex-end; display: inline-flex; align-items: center; gap: 4px; margin-top: -16px; }
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
