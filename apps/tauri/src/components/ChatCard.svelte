<script lang="ts">
  // Unified chat card for the bar (`ChatNoticeCard` / `ChatCard` on the Mac, CH-65): works for every chat app
  // (WhatsApp, Telegram, Signal, Messenger, Slack, Teams, Discord, …) with app logo, sender avatar, priority badge
  // (CH-64), live in-place message updates (CH-68), reply-with-mark-read (CH-68), "Let Nook reply", and actions
  // respecting `ChatAbilities` (CH-58).
  import { tick } from "svelte";
  import { listen as listenEvent } from "@tauri-apps/api/event";
  import {
    abilitiesForApp,
    appName,
    bubbleOfInbox,
    bubbleOfWhatsApp,
    chatApps,
    fillReceipts,
    personTint,
    priorityBadge,
    typingLine,
    whatsAppKey,
    type Bubble,
    type ChatAbilities,
    type NoticeScore,
  } from "../lib/chats-list";
  import { arrivedChat, showChat, type ChatArrived } from "../lib/chat-arrived.svelte";
  import { chatsApi, connectorEvents, connectorsApi, type ChatSummary, type ChatThread } from "../lib/connectors";
  import { tr } from "../lib/i18n.svelte";
  import { toast } from "../lib/toast.svelte";
  import { bubbleText, fileLabel, time } from "../lib/whatsapp";
  import { whatsapp } from "../lib/whatsapp.svelte";
  import { invokeOrFallback } from "../views/chats/chat-actions.svelte";
  import ChatFace from "../views/chats/ChatFace.svelte";
  import Ticks from "../views/chats/Ticks.svelte";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";
  import Ico from "./ui/Ico.svelte";
  import ImageModal from "./ui/ImageModal.svelte";

  type CardSource = "auto" | "whatsapp" | "arrived";
  type ExtendedArrived = ChatArrived & { priority?: NoticeScore | null };
  type ExtendedSummary = ChatSummary & { abilities?: ChatAbilities; priority?: NoticeScore | null };

  let {
    source = "auto",
    key = null,
    priority = null,
    onnook,
    onopen,
    inline = false,
  }: {
    source?: CardSource;
    key?: string | null;
    priority?: NoticeScore | null;
    onnook?: (nookId: string) => void;
    onopen?: (key: string) => void;
    inline?: boolean;
  } = $props();

  // Explicit key state (when the caller mounts `<ChatCard key="telegram#42" />` directly).
  let explicitThread = $state<ChatThread | null>(null);
  let explicitDraft = $state("");
  let explicitSending = $state(false);
  let explicitError = $state<string | null>(null);

  // Live metadata updated from backend events without disturbing an in-progress draft.
  let livePriority = $state<NoticeScore | null>(null);
  let liveAbilities = $state<ChatAbilities | null>(null);
  let liveTyping = $state<string[]>([]);
  let askingNook = $state(false);

  const mode = $derived.by<"explicit" | "whatsapp" | "arrived" | null>(() => {
    if (key) return "explicit";
    if (source === "whatsapp") return whatsapp.card?.conversation ? "whatsapp" : null;
    if (source === "arrived") return arrivedChat.thread ? "arrived" : null;
    if (whatsapp.card?.conversation) return "whatsapp";
    if (arrivedChat.thread) return "arrived";
    return null;
  });

  const waCard = $derived(mode === "whatsapp" ? whatsapp.card : null);
  const waConv = $derived(waCard?.conversation ?? null);
  const activeThread = $derived(
    mode === "explicit" ? explicitThread : mode === "arrived" ? arrivedChat.thread : null,
  );

  const activeKey = $derived(
    mode === "explicit"
      ? key ?? ""
      : mode === "whatsapp" && waConv
        ? whatsAppKey(waConv.id)
        : activeThread?.key ?? "",
  );
  const appId = $derived(
    mode === "whatsapp" ? "whatsapp" : activeThread?.app ?? (activeKey.includes("#") ? activeKey.slice(0, activeKey.indexOf("#")) : ""),
  );
  const chatId = $derived(
    mode === "whatsapp" && waConv ? waConv.id : activeKey.includes("#") ? activeKey.slice(activeKey.indexOf("#") + 1) : activeKey,
  );
  const isWhatsApp = $derived(appId === "whatsapp");
  const title = $derived(mode === "whatsapp" ? waConv?.name ?? "" : activeThread?.name ?? "");
  const isGroup = $derived(
    mode === "whatsapp"
      ? !!(waConv?.isGroup || waConv?.kind === "group")
      : activeThread?.kind === "group",
  );
  const unreadCount = $derived(
    mode === "whatsapp"
      ? waConv?.unread ?? 0
      : activeThread?.read.state === "unread"
        ? activeThread.read.count
        : (arrivedChat.pending?.key === activeKey ? arrivedChat.pending.unread : 0),
  );
  const sends = $derived(mode === "whatsapp" ? true : (activeThread?.sends ?? false));
  const abilities = $derived<ChatAbilities>(liveAbilities ?? abilitiesForApp(appId || "whatsapp", sends));
  const effectivePriority = $derived<NoticeScore | null>(
    priority ?? livePriority ?? ((arrivedChat.pending as ExtendedArrived | null)?.key === activeKey ? (arrivedChat.pending as ExtendedArrived).priority ?? null : null),
  );
  const badge = $derived(priorityBadge(effectivePriority));
  const typingText = $derived(typingLine(liveTyping, isGroup, title));

  const rawBubbles = $derived<Bubble[]>(
    mode === "whatsapp" && waConv
      ? waConv.messages.map(bubbleOfWhatsApp)
      : (activeThread?.messages ?? []).filter((m) => !m.deleted).map(bubbleOfInbox),
  );
  const visibleBubbles = $derived<Bubble[]>(fillReceipts(rawBubbles, !isGroup).slice(inline ? -40 : -8));
  const runs = $derived.by(() => {
    const list = visibleBubbles;
    const who = (m: Bubble) => (m.fromMe ? "\u0000me" : m.sender || "");
    return list.map((m, i) => ({
      m,
      first: !list[i - 1] || who(list[i - 1]) !== who(m),
      last: !list[i + 1] || who(list[i + 1]) !== who(m),
    }));
  });

  // Refresh explicit thread, inbox summary metadata (priority + abilities), and keep the open card live (CH-68).
  async function refreshActive(targetKey: string) {
    if (!targetKey) return;
    if (mode === "explicit") {
      try {
        const next = await chatsApi.thread(targetKey);
        if (activeKey === targetKey && next) explicitThread = next;
      } catch {
        // Keep current messages on transient failure.
      }
    } else if (mode === "whatsapp") {
      await whatsapp.reload();
    } else if (mode === "arrived") {
      await arrivedChat.reload();
    }
    try {
      const list = (await chatsApi.list()) as ExtendedSummary[];
      const match = list.find((s) => s.key === targetKey);
      if (activeKey === targetKey && match) {
        if (match.abilities) liveAbilities = match.abilities;
        if (match.priority) livePriority = match.priority;
      }
    } catch {
      // Fall back to derived abilities and existing priority.
    }
  }

  $effect(() => {
    const targetKey = activeKey;
    if (!targetKey) return;
    liveTyping = [];
    liveAbilities = null;
    if (priority) livePriority = priority;
    else livePriority = null;
    void refreshActive(targetKey);

    const offChats = connectorEvents.onChats(() => {
      void refreshActive(targetKey);
    });
    const offChanged = connectorEvents.onChanged(() => {
      void refreshActive(targetKey);
    });
    const offWaMsg = connectorEvents.onWhatsApp((arrived) => {
      if (isWhatsApp && arrived.chat === chatId) {
        void whatsapp.reload();
      }
    });
    const offWaReceipt = connectorEvents.onWhatsAppReceipt((id) => {
      if (isWhatsApp && id === chatId) {
        void whatsapp.reload();
      }
    });
    const offArrived = listenEvent<ExtendedArrived>("chat-arrived", (e) => {
      if (e.payload?.key !== targetKey) return;
      if (e.payload.priority) livePriority = e.payload.priority;
      void refreshActive(targetKey);
    });
    const offTyping = listenEvent<{ key: string; typing: string[] }>("chat-typing", (e) => {
      if (e.payload?.key === targetKey) liveTyping = e.payload.typing ?? [];
    });

    return () => {
      offChats.then((f) => f());
      offChanged.then((f) => f());
      offWaMsg.then((f) => f());
      offWaReceipt.then((f) => f());
      offArrived.then((f) => f());
      offTyping.then((f) => f());
    };
  });

  // Auto-scroll to bottom when opening a chat or when a live message arrives.
  let scroller = $state<HTMLDivElement | null>(null);
  let lastScrollMarker = "";
  $effect(() => {
    const lastId = visibleBubbles[visibleBubbles.length - 1]?.id ?? "";
    const marker = `${activeKey}#${lastId}#${visibleBubbles.length}`;
    if (!activeKey || marker === lastScrollMarker) return;
    lastScrollMarker = marker;
    tick().then(() => {
      if (scroller) scroller.scrollTop = scroller.scrollHeight;
    });
  });

  // WhatsApp media previews and inline voice playback.
  const enlarged = $derived(isWhatsApp && whatsapp.enlarged ? waCard?.previews[whatsapp.enlarged]?.image ?? null : null);
  let sounds = $state<Record<string, string>>({});
  let loadingSound = $state<string | null>(null);
  async function listen(m: Bubble) {
    if (!isWhatsApp || !chatId || sounds[m.id] || loadingSound) return;
    loadingSound = m.id;
    whatsapp.notice = "";
    try {
      const { mime, base64 } = await connectorsApi.whatsappAudio(chatId, m.id);
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      sounds[m.id] = URL.createObjectURL(new Blob([bytes], { type: mime }));
    } catch (e) {
      whatsapp.notice = String(e);
    } finally {
      loadingSound = null;
    }
  }
  const isSound = (m: Bubble) => m.media.kind === "voice" || m.media.kind === "audio";
  const photo = (m: Bubble) => (isWhatsApp && m.media.kind === "image" ? waCard?.previews[m.id]?.image ?? null : null);
  const textOf = (m: Bubble) => bubbleText({ ...m, chat: chatId, senderName: m.sender, media: m.media });

  // Unified draft / sending / notice accessors.
  function currentDraft(): string {
    return mode === "whatsapp" ? whatsapp.draft : mode === "arrived" ? arrivedChat.draft : explicitDraft;
  }
  function setDraft(value: string) {
    if (mode === "whatsapp") whatsapp.draft = value;
    else if (mode === "arrived") arrivedChat.draft = value;
    else explicitDraft = value;
  }
  const sending = $derived(
    mode === "whatsapp" ? whatsapp.sending : mode === "arrived" ? arrivedChat.sending : explicitSending,
  );
  const noticeText = $derived(
    mode === "whatsapp" ? whatsapp.notice : mode === "arrived" ? arrivedChat.error : explicitError,
  );
  const canSend = $derived(abilities.send && !!currentDraft().trim() && !sending);

  // CH-68: Reply sends the message AND marks the chat read across WhatsApp + helper apps.
  async function sendReply() {
    if (!canSend || !activeKey) return;
    if (mode === "whatsapp") {
      await whatsapp.send();
      return;
    }
    const text = currentDraft().trim();
    if (!text) return;
    if (mode === "arrived") {
      arrivedChat.sending = true;
      arrivedChat.error = null;
    } else {
      explicitSending = true;
      explicitError = null;
    }
    setDraft("");
    try {
      await chatsApi.send(activeKey, text, null);
      await chatsApi.markRead(activeKey, abilities.markRead).catch(() => {});
      whatsapp.version++;
      if (mode === "arrived" && !inline) {
        arrivedChat.dismiss();
        toast.success(tr("Verstuurd naar {name}", "Sent to {name}", { name: title }));
      } else {
        await refreshActive(activeKey);
      }
    } catch (e) {
      if (mode === "arrived") arrivedChat.error = String(e);
      else explicitError = String(e);
      if (!currentDraft().trim()) setDraft(text);
    } finally {
      if (mode === "arrived") arrivedChat.sending = false;
      else explicitSending = false;
    }
  }

  // CH-68: Mark read respects `abilities.markRead` (in-app when supported, else in Nook).
  async function markRead() {
    if (!activeKey) return;
    if (mode === "whatsapp") {
      await whatsapp.markRead();
      return;
    }
    await chatsApi.markRead(activeKey, abilities.markRead).catch(() => {});
    whatsapp.version++;
    if (mode === "arrived" && !inline) arrivedChat.dismiss();
    else await refreshActive(activeKey);
  }

  function dismissCard() {
    if (mode === "whatsapp") whatsapp.dismiss();
    else if (mode === "arrived") arrivedChat.dismiss();
    else explicitThread = null;
  }

  async function muteChat() {
    if (!activeKey) return;
    if (mode === "whatsapp") {
      await whatsapp.mute();
      return;
    }
    try {
      await invokeOrFallback("chat_set_muted", { key: activeKey, muted: true }, async () => {
        if (abilities.mute) await chatsApi.inApp(activeKey, { muted: true });
      });
      whatsapp.version++;
      if (mode === "arrived" && !inline) arrivedChat.dismiss();
    } catch (e) {
      toast.error(tr("Dat lukte niet", "That did not work"), e);
    }
  }

  // CH-65: "Let Nook reply" works for WhatsApp AND every helper chat app.
  async function letNookReply() {
    if (!activeKey || askingNook) return;
    askingNook = true;
    try {
      if (mode === "whatsapp") {
        const id = await whatsapp.askNook();
        if (id) onnook?.(id);
        return;
      }
      const id = await invokeOrFallback<string | null>(
        "chat_ask_nook",
        { key: activeKey },
        async () => {
          const drafted = await chatsApi.draft(activeKey, "");
          if (drafted) setDraft(drafted);
          return null;
        },
      );
      if (id) {
        if (mode === "arrived" && !inline) arrivedChat.dismiss();
        onnook?.(id);
      }
    } catch (e) {
      if (mode === "whatsapp") whatsapp.notice = String(e);
      else if (mode === "arrived") arrivedChat.error = String(e);
      else explicitError = String(e);
    } finally {
      askingNook = false;
    }
  }

  function openInNook() {
    if (!activeKey) return;
    if (onopen) onopen(activeKey);
    else showChat(activeKey, true);
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      void sendReply();
    }
  }
</script>

{#if mode && activeKey && title}
  <div class="chat-card" class:inline role="region" aria-label={title}>
    <div class="head">
      <div class="context">
        <ServiceIcon domain={chatApps[appId]?.domain} title={appName(appId)} size={16} />
        <span class="ctx-text">
          {appName(appId)}{#if unreadCount > 0} · {tr("{n} ongelezen", "{n} unread", { n: unreadCount })}{/if}
        </span>
        {#if badge}
          <span class="priority-badge" class:urgent={badge.tone === "urgent"}>
            <Ico name={badge.icon} size={11} stroke={2.5} />
            <span>{badge.label}</span>
          </span>
        {/if}
      </div>
      <div class="who">
        <ChatFace id={chatId} app={appId} name={title} size={28} badge={false} />
        <div class="who-text">
          <h3 class="title">{title}</h3>
          {#if typingText}<span class="typing">{typingText}</span>{/if}
        </div>
      </div>
    </div>

    <div class="bubbles" bind:this={scroller}>
      {#if isWhatsApp && rawBubbles.length > visibleBubbles.length}
        <div class="older">{tr("Scroll omhoog voor oudere berichten", "Scroll up for older messages")}</div>
      {/if}
      {#each runs as { m, first, last } (m.id)}
        {@const file = fileLabel(m.media)}
        {@const image = photo(m)}
        {@const text = file ? m.text : textOf(m)}
        <div class="line" class:mine={m.fromMe} class:first>
          <div class="bubble" class:mine={m.fromMe} class:tailed={first} class:joins={!last} class:bare={!!image && !text}>
            {#if first && isGroup && !m.fromMe && m.sender && m.sender !== title}
              <span class="sender" style:color={personTint(m.sender)}>{m.sender}</span>
            {/if}
            {#if image}
              <button class="photo" title={tr("Groot bekijken", "View larger")} onclick={() => (whatsapp.enlarged = m.id)}>
                <img src={image} alt={file ?? tr("Foto", "Photo")} />
              </button>
            {:else if file}
              <div class="file">
                <Ico name={m.media.kind === "video" ? "play" : m.media.kind === "document" ? "file" : m.media.kind === "image" ? "image" : "mic"} size={14} />
                <span class="file-name">{file}</span>
                {#if isWhatsApp}
                  {#if isSound(m)}
                    {#if sounds[m.id]}
                      <!-- svelte-ignore a11y_media_has_caption -->
                      <audio controls autoplay src={sounds[m.id]}></audio>
                    {:else}
                      <button class="file-btn" onclick={() => listen(m)} disabled={loadingSound === m.id}>
                        {loadingSound === m.id ? tr("Laden…", "Loading…") : tr("Afspelen", "Play")}
                      </button>
                    {/if}
                  {:else}
                    <button class="file-btn" onclick={() => whatsapp.open(m.id, file)}>
                      {m.media.kind === "video" ? tr("Video afspelen", "Play video") : tr("Openen", "Open")}
                    </button>
                  {/if}
                {/if}
              </div>
            {/if}
            <span class="msg-body">
              {#if text}<span class="text">{text}</span>{/if}
              {#if last || m.fromMe}
                <span class="stamp">
                  {time(m.date)}{#if m.fromMe}<Ticks receipt={m.receipt} size={11} />{/if}
                </span>
              {/if}
            </span>
          </div>
        </div>
      {/each}
    </div>

    {#if noticeText}<div class="notice">{noticeText}</div>{/if}

    {#if abilities.send}
      <form class="reply-box" onsubmit={(e) => { e.preventDefault(); void sendReply(); }}>
        <input
          value={currentDraft()}
          oninput={(e) => setDraft((e.currentTarget as HTMLInputElement).value)}
          onkeydown={keydown}
          placeholder={tr("Antwoord aan {name}", "Reply to {name}", { name: title })}
          aria-label={tr("Antwoord aan {name}", "Reply to {name}", { name: title })}
          disabled={sending}
        />
        <button class="send" class:ready={canSend} type="submit" disabled={!canSend} aria-label={tr("Versturen", "Send")}>
          <Ico name="arrow-up" size={14} stroke={2.5} />
        </button>
      </form>
    {/if}

    <div class="actions-row">
      <div class="split-pill">
        <button class="split-primary" onclick={markRead}>
          <Ico name={abilities.markRead ? "check-check" : "check"} size={13} stroke={2.5} />
          <span>{tr("Gelezen", "Read")}</span>
        </button>
        <button class="split-secondary" onclick={dismissCard}>
          {tr("Later", "Later")}
        </button>
      </div>
      {#if abilities.send}
        <button class="extra" onclick={letNookReply} disabled={askingNook}>
          <Ico name="sparkles" size={13} />
          <span>{tr("Laat Nook antwoorden", "Let Nook reply")}</span>
        </button>
      {/if}
      {#if abilities.mute || isWhatsApp}
        <button class="extra" onclick={muteChat} title={tr("Dempen", "Mute")}>
          <Ico name="bell-off" size={13} />
          <span>{tr("Dempen", "Mute")}</span>
        </button>
      {/if}
      <button class="extra" onclick={openInNook}>
        <Ico name="messages-square" size={13} />
        <span>{tr("Open in Nook", "Open in Nook")}</span>
      </button>
    </div>
  </div>
{/if}

{#if enlarged}
  <ImageModal
    src={enlarged}
    alt={tr("Foto", "Photo")}
    onclose={() => (whatsapp.enlarged = null)}
    onopen={() => whatsapp.enlarged && whatsapp.open(whatsapp.enlarged, tr("Foto", "Photo"))}
  />
{/if}

<style>
  .chat-card {
    margin: var(--space-8) var(--space-16) var(--space-4);
    padding: var(--space-12) var(--space-16);
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: var(--radius-panel);
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    min-width: 0;
  }
  .chat-card.inline {
    margin: 0;
    height: 100%;
    box-sizing: border-box;
    border: 0;
    border-radius: 0;
  }
  .inline .bubbles { flex: 1; min-height: 0; max-height: none; }

  .head { display: flex; flex-direction: column; gap: var(--space-6); min-width: 0; }
  .context { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .ctx-text { font: var(--text-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .priority-badge {
    margin-left: auto;
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    padding: var(--space-2) var(--space-8);
    border-radius: 999px;
    background: color-mix(in srgb, var(--amber) 16%, transparent);
    color: var(--amber);
    font: var(--text-caption);
    font-weight: 600;
    white-space: nowrap;
  }
  .priority-badge.urgent {
    background: color-mix(in srgb, var(--coral) 18%, transparent);
    color: var(--coral);
  }

  .who { display: flex; align-items: center; gap: var(--space-8); min-width: 0; }
  .who-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .title { margin: 0; font: var(--text-heading); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .typing { font: var(--text-caption); color: var(--mint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .bubbles { display: flex; flex-direction: column; max-height: 210px; overflow-y: auto; padding: var(--space-2) 0; }
  .older { font: var(--text-caption); color: var(--text3); text-align: center; padding-bottom: var(--space-4); }
  .line { display: flex; padding-top: var(--space-2); padding-right: 48px; }
  .line.first { padding-top: var(--space-6); }
  .line:first-child { padding-top: 0; }
  .line.mine { justify-content: flex-end; padding-right: 0; padding-left: 48px; }
  .bubble {
    position: relative;
    max-width: 100%;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-6) var(--space-10, 10px);
    margin-left: 7px;
    background: var(--chat-theirs);
    border-radius: var(--radius-chat-bubble);
    color: var(--paper);
    user-select: text;
  }
  .bubble.mine { margin-left: 0; margin-right: 7px; background: var(--chat-mine); }
  .bubble:not(.tailed) { border-top-left-radius: var(--radius-chat-join); }
  .bubble.mine:not(.tailed) { border-top-left-radius: var(--radius-chat-bubble); border-top-right-radius: var(--radius-chat-join); }
  .bubble.joins { border-bottom-left-radius: var(--radius-chat-join); }
  .bubble.mine.joins { border-bottom-left-radius: var(--radius-chat-bubble); border-bottom-right-radius: var(--radius-chat-join); }
  .bubble.tailed { border-top-left-radius: 0; }
  .bubble.mine.tailed { border-top-left-radius: var(--radius-chat-bubble); border-top-right-radius: 0; }
  .bubble.tailed::before {
    content: "";
    position: absolute;
    top: 0;
    left: -7px;
    width: 7px;
    height: 9px;
    background: inherit;
    clip-path: polygon(0 0, 100% 0, 100% 100%);
  }
  .bubble.mine.tailed::before { left: auto; right: -7px; clip-path: polygon(0 0, 100% 0, 0 100%); }
  .bubble.bare { padding: 0; background: transparent; }
  .bubble.bare::before { display: none; }

  .sender { font: var(--text-label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .msg-body { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: flex-end; column-gap: var(--space-8); }
  .msg-body:empty { display: none; }
  .text { flex: 1 1 auto; min-width: 0; font: var(--text-body); color: var(--paper); white-space: pre-wrap; overflow-wrap: anywhere; }
  .stamp { margin-left: auto; display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--chat-stamp); white-space: nowrap; }

  .photo { padding: 0; border: 0; background: none; cursor: zoom-in; display: block; }
  .photo img { display: block; max-width: 240px; max-height: 180px; border-radius: var(--radius-card); object-fit: cover; }
  .file { display: flex; align-items: center; gap: var(--space-6); font: var(--text-detail); color: var(--text2); }
  .file-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--paper); }
  .file audio { height: 32px; min-width: 0; flex: 1; }
  .file-btn { padding: var(--space-2) var(--space-8); border: 1px solid var(--separator); border-radius: var(--radius-control); background: var(--smoke); color: var(--paper); font: var(--text-caption); font-weight: 600; cursor: pointer; }

  .notice { font: var(--text-detail); color: var(--coral); }

  .reply-box {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-4) var(--space-4) var(--space-4) var(--space-12);
    background: var(--composer-tray);
    border: 1px solid var(--field-stroke);
    border-radius: var(--radius-composer);
    transition: background var(--motion-quick), border-color var(--motion-quick);
  }
  .reply-box:focus-within { background: var(--composer); border-color: var(--separator); }
  .reply-box input {
    flex: 1;
    min-width: 0;
    padding: var(--space-4) 0;
    border: 0;
    background: transparent;
    box-shadow: none;
    outline: none;
    font: var(--text-body);
    color: var(--paper);
  }
  .reply-box input::placeholder { color: var(--text3); }
  .send {
    flex: none;
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 0;
    border-radius: 999px;
    background: var(--smoke);
    color: var(--text3);
    cursor: default;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .send.ready { background: var(--iris); color: var(--on-iris); cursor: pointer; }
  .send.ready:hover:not(:disabled) { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }

  .actions-row { display: flex; align-items: center; gap: var(--space-4); flex-wrap: wrap; }
  .split-pill {
    display: inline-flex;
    align-items: center;
    height: 36px;
    padding: 3px;
    box-sizing: border-box;
    background: var(--smoke);
    border-radius: var(--radius-control);
  }
  .split-primary {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 100%;
    padding: 0 var(--space-16);
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--iris);
    color: var(--on-iris);
    font: var(--text-emphasis);
    font-weight: 600;
    cursor: pointer;
    transition: background var(--motion-quick);
  }
  .split-primary:hover { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }
  .split-secondary {
    display: inline-flex;
    align-items: center;
    height: 100%;
    padding: 0 var(--space-16);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text2);
    font: var(--text-emphasis);
    font-weight: 600;
    cursor: pointer;
    transition: color var(--motion-quick);
  }
  .split-secondary:hover { color: var(--paper); }
  .extra {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 36px;
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    font: var(--text-control);
    cursor: pointer;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .extra:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
</style>
