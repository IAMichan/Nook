<script lang="ts" module>
  /// What you were typing to each chat stays while Nook runs, and comes back when you open the chat again.
  const drafts = new Map<string, string>();
</script>

<script lang="ts">
  // The chat on the right (`ChatsDetail`): who and which app on top, the messages as bubbles (theirs on the left in
  // `--chat-theirs`, yours on the right in `--chat-mine`, the first of a run with a tail), and one field to answer
  // below (`ChatReplyField`). The same for every chat app: the messages come from the shared inbox (with what they
  // answer and their reactions), WhatsApp's photos, files and voice notes from its card. A message's chevron or a
  // right-click reacts, replies, forwards, copies, edits or deletes it, where its app lets Nook. Scrolling to the top
  // brings older messages without moving what you read. Everything from a message is shown as text, never as HTML.
  import { tick } from "svelte";
  import { listen as listenEvent } from "@tauri-apps/api/event";
  import { chatsApi, connectorEvents, connectorsApi, type ChatThread } from "../../lib/connectors";
  import { noticeText } from "../../lib/chat-notice";
  import { appName, bubbleOfInbox, callDetail, callOf, callTitle, canForwardTo, dayAndClock, entryAbilities, fillReceipts, firstLink, bubbleOfWhatsApp, COMMON_EMOJI, dayLabel, frequentEmoji, insertTag, outgoingKindOfMedia, personTint, QUICK_REACTIONS, readReceiptSummary, typingLine, typingTag, usedEmoji, type Bubble, type ChatEntry } from "../../lib/chats-list";
  import Dialog from "../../components/ui/Dialog.svelte";
  import TimelineEarlierRow from "../../components/ui/TimelineEarlierRow.svelte";
  import ChatQuote from "./ChatQuote.svelte";
  import ChatForwardSheet from "./ChatForwardSheet.svelte";
  import ChatInfo from "./ChatInfo.svelte";
  import LinkCard from "./LinkCard.svelte";
  import ActionSuggestionBar from "../../components/ActionSuggestionBar.svelte";
  import type { Line as SuggestionLine, Turn as SuggestionTurn } from "../../lib/action-suggestions.svelte";
  import ReactionChips from "./ReactionChips.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { bubbleText, fileLabel, time } from "../../lib/whatsapp";
  import { whatsapp } from "../../lib/whatsapp.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import IconButton from "../../components/ui/IconButton.svelte";
  import ImageModal from "../../components/ui/ImageModal.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import CountBadge from "../../components/ui/CountBadge.svelte";
  import ChatFace from "./ChatFace.svelte";
  import CallIcon from "./CallIcon.svelte";
  import ChatCallCard from "./ChatCallCard.svelte";
  import Ticks from "./Ticks.svelte";
  import { canCallChat } from "../../lib/chats-call";
  import { activeCall } from "../../lib/chats-call.svelte";
  import { chatOptions } from "../../lib/chat-options.svelte";
  import ChatGifShelf from "./ChatGifShelf.svelte";
  import ChatPollForm from "./ChatPollForm.svelte";
  import ChatPollView from "./ChatPollView.svelte";
  import DropdownRow from "../../components/ui/DropdownRow.svelte";
  import Dropdown from "../../components/ui/Dropdown.svelte";
  import DropdownTileGrid from "../../components/ui/DropdownTileGrid.svelte";
  import { chatMenu, invokeOrFallback, isChatArchived, isChatMuted, isChatPinned, markReadInApp, markReadInNook, openChatSettings } from "./chat-actions.svelte";

  let { entry, targets = [], onclose, onnook, onopenchat }: {
    entry: ChatEntry;
    /** The chats a message can be forwarded to. */
    targets?: ChatEntry[];
    onclose: () => void;
    onnook: (nookId: string) => void;
    /** Opens another chat by its key (a group you share, in a chat's info). */
    onopenchat?: (key: string) => void;
  } = $props();

  const isWhatsApp = $derived(entry.app === "whatsapp");
  const app = $derived(appName(entry.app));
  const isGroup = $derived(entry.isGroup);
  const abilities = $derived(entryAbilities(entry));

  // The chat from the shared inbox, read again whenever it changes (WhatsApp's too: its card fills it).
  let thread = $state<ChatThread | null>(null);
  let liveTyping = $state<string[] | null>(null);
  async function loadThread() {
    try {
      thread = await chatsApi.thread(entry.key);
    } catch {
      // Keep what shows.
    }
  }
  $effect(() => {
    const key = entry.key;
    liveTyping = null;
    loadThread();
    const off = connectorEvents.onChats(loadThread);
    const offWa = connectorEvents.onChanged(loadThread);
    const offTyping = listenEvent<{ key: string; typing: string[] }>("chat-typing", (e) => {
      if (e.payload?.key === key) liveTyping = e.payload.typing ?? [];
    });
    return () => {
      off.then((f) => f());
      offWa.then((f) => f());
      offTyping.then((f) => f());
    };
  });
  // WhatsApp's card brought something (older messages, ticks): the inbox has it too.
  $effect(() => {
    void whatsapp.card;
    if (entry.app === "whatsapp") loadThread();
  });

  const conversation = $derived(whatsapp.card?.conversation.id === entry.id ? whatsapp.card.conversation : null);
  const rawBubbles = $derived<Bubble[]>(
    thread?.messages.length ? thread.messages.map(bubbleOfInbox) : isWhatsApp ? (conversation?.messages ?? []).map(bubbleOfWhatsApp) : [],
  );
  const bubbles = $derived<Bubble[]>(fillReceipts(rawBubbles, !isGroup));
  const byId = $derived(new Map(bubbles.map((b) => [b.id, b])));
  const lastMineId = $derived.by(() => {
    for (let i = bubbles.length - 1; i >= 0; i--) {
      if (bubbles[i].fromMe && !bubbles[i].deleted) return bubbles[i].id;
    }
    return null;
  });
  // CH-68: opening an unread chat marks it read in Nook once visible, and re-runs only if a newer incoming message
  // arrives while the chat stays open (so manually marking a chat unread stays sticky until something new comes in).
  let autoReadMarker = "";
  $effect(() => {
    const key = entry.key;
    const isUnread = entry.read === "unread" || thread?.read.state === "unread";
    // "Read in Nook when opened", and "Also read in the app" where its app takes it (Settings › Chat options).
    const how = chatOptions.readWhenOpened(!!abilities.markRead);
    if (!isUnread || how === "no") return;
    let newestIncoming = "";
    for (let i = bubbles.length - 1; i >= 0; i--) {
      if (!bubbles[i].fromMe && !bubbles[i].deleted) {
        newestIncoming = bubbles[i].id;
        break;
      }
    }
    const marker = `${key}#${newestIncoming || entry.unread}`;
    if (marker === autoReadMarker) return;
    const timer = setTimeout(() => {
      if (document.hidden) return;
      autoReadMarker = marker;
      chatsApi.markRead(key, how === "app")
        .then(() => { whatsapp.version++; })
        .catch(() => {});
    }, 550);
    return () => clearTimeout(timer);
  });
  const activeTyping = $derived(
    liveTyping ?? ((thread as (ChatThread & { typing?: string[] }) | null)?.typing ?? entry.typing ?? []),
  );
  const typingText = $derived(typingLine(activeTyping, isGroup, entry.name));
  // A group's people, for "@" in the field and its info: from the inbox, else asked of its app once.
  let asked = $state<string[]>([]);
  $effect(() => {
    if (!entry.isGroup) return;
    chatsApi.people(entry.key).then((p) => (asked = p)).catch(() => {});
  });
  const people = $derived(thread?.people.length ? thread.people : asked);
  const enlarged = $derived(whatsapp.enlarged ? whatsapp.card?.previews[whatsapp.enlarged]?.image ?? null : null);

  // The messages in runs: a run is one writer's messages in a row on one day. The first carries the tail (and the
  // writer's name in a group), the last the time.
  type Line = { kind: "day"; id: string; label: string } | { kind: "notice"; m: Bubble; text: string } | { kind: "bubble"; m: Bubble; first: boolean; last: boolean };
  // Where what is new begins: the first of the newest `unread` messages from someone else, as the chat opened.
  const unreadAtOpen = (() => entry.unread)();
  const newFrom = $derived.by(() => {
    if (!unreadAtOpen) return null;
    const theirs = bubbles.filter((b) => !b.fromMe && !noticeText(b));
    return theirs[Math.max(0, theirs.length - unreadAtOpen)]?.id ?? null;
  });
  const lines = $derived.by(() => {
    const now = new Date();
    const out: Line[] = [];
    const who = (m: Bubble) => (noticeText(m) ? `\u0000notice:${m.id}` : m.fromMe ? "\u0000me" : m.sender);
    let day = "";
    bubbles.forEach((m, i) => {
      const d = new Date(m.date);
      const key = Number.isNaN(d.getTime()) ? day : d.toDateString();
      if (key !== day) {
        day = key;
        // No line above the first message when the whole chat is from today: the header says when (`ChatTimeline`).
        const today = new Date().toDateString();
        const allToday = !out.length && bubbles.every((b) => new Date(b.date).toDateString() === today);
        if (!Number.isNaN(d.getTime()) && !allToday) out.push({ kind: "day", id: `day:${key}`, label: dayLabel(d, now) });
      }
      // A line about the group stands alone in the middle (`ChatNoticeLine`), its time on hover.
      const notice = noticeText(m);
      if (notice) {
        out.push({ kind: "notice", m, text: notice });
        return;
      }
      const prev = bubbles[i - 1];
      const next = bubbles[i + 1];
      const sameDay = (a?: Bubble) => !!a && new Date(a.date).toDateString() === key;
      out.push({
        kind: "bubble", m,
        first: !prev || who(prev) !== who(m) || !sameDay(prev),
        last: !next || who(next) !== who(m) || !sameDay(next),
      });
    });
    return out;
  });

  let scroller = $state<HTMLDivElement | null>(null);
  let field = $state<HTMLTextAreaElement | null>(null);
  // A new chat or a new message: the newest at the bottom in view; scrolling up shows the older ones. Older messages
  // that come in above keep what you read where it was (`TranscriptReadingAnchor`).
  let lastShown = "";
  let anchor: { height: number; top: number } | null = null;
  $effect(() => {
    const key = `${entry.key}#${bubbles[bubbles.length - 1]?.id ?? ""}`;
    const count = bubbles.length;
    if (key === lastShown) {
      if (anchor && scroller) {
        const held = anchor;
        tick().then(() => scroller && (scroller.scrollTop = scroller.scrollHeight - held.height + held.top));
        anchor = null;
      }
      return;
    }
    lastShown = key;
    void count;
    tick().then(() => scroller && (scroller.scrollTop = scroller.scrollHeight));
  });

  // Older messages: asked for at the top of the chat, once at a time, while the app has more (`ChatHistoryBridge`).
  let loadingOlder = $state(false);
  let noOlder = $state(false);
  const hasOlder = $derived(!noOlder && (thread?.hasOlder ?? false) || (!noOlder && isWhatsApp && bubbles.length > 0));
  async function older() {
    if (loadingOlder || !scroller) return;
    loadingOlder = true;
    anchor = { height: scroller.scrollHeight, top: scroller.scrollTop };
    try {
      const more = await chatsApi.older(entry.key);
      if (!more) noOlder = true;
      await loadThread();
    } catch (e) {
      notice = String(e);
      anchor = null;
    } finally {
      loadingOlder = false;
    }
  }
  function scrolled() {
    if (scroller && scroller.scrollTop < 40 && hasOlder) older();
  }
  // An opened chat puts the cursor in the field, with what you were typing to it.
  // The parent keys this view by chat, so the draft is read once per chat.
  let draft = $state(drafts.get((() => entry.key)()) ?? "");
  $effect(() => {
    drafts.set(entry.key, draft);
  });
  $effect(() => {
    void entry.key;
    tick().then(() => field?.focus());
  });

  let notice = $state("");
  let sending = $state(false);
  /// The message the field answers: it shows above the field until the answer goes (`ChatQuote`).
  let replying = $state<Bubble | null>(null);
  /// Your own message whose words the field changes (`chat.editing`).
  let editing = $state<Bubble | null>(null);
  /// Files chosen with "+", dropped or pasted: they go with the next send, the text as the first one's caption.
  let files = $state<File[]>([]);
  const ready = $derived((!!draft.trim() || files.length > 0) && !sending);

  /** Return or the arrow: the text goes to this chat as typed, as an answer to the quoted message when there is one;
   *  the chat stays open and shows it. When it fails the chat says why and the text and the quote are back. A chat Nook
   *  cannot write in copies the text for its app instead. */
  // "@nook …" (`ChatDraft`): Nook writes the message into the field, for you to read and send yourself.
  let writing = $state(false);
  function nookInstruction(text: string): string | null {
    const t = text.trim();
    if (!/^@nook(?![\p{L}\p{N}])/iu.test(t)) return null;
    return t.slice(5).replace(/^[\s,:;\-–—]+/, "").trim();
  }
  async function writeWithNook(instruction: string) {
    writing = true;
    notice = "";
    try {
      draft = await chatsApi.draft(entry.key, instruction);
      tick().then(() => field?.focus());
    } catch (e) {
      notice = String(e);
    } finally {
      writing = false;
    }
  }

  // The answer you will likely send (`ChatReplySuggestion`): grey in the empty field when the newest message is
  // someone else's; Tab puts it in the field, typing hides it. One try per message.
  let suggestion = $state<{ turn: string; text: string } | null>(null);
  let askedTurn = "";
  $effect(() => {
    const last = bubbles[bubbles.length - 1];
    if (!last || last.fromMe || !entry.sends || askedTurn === last.id) return;
    askedTurn = last.id;
    const turn = last.id;
    chatsApi.suggestReply(entry.key).then((text) => { if (text && askedTurn === turn) suggestion = { turn, text }; }).catch(() => {});
  });
  const ghost = $derived(suggestion && !draft && suggestion.turn === bubbles[bubbles.length - 1]?.id ? suggestion.text : null);

  async function send() {
    const text = draft.trim();
    if (editing) return saveEdit();
    const asked = nookInstruction(text);
    if (asked !== null && entry.sends) return writeWithNook(asked);
    if (files.length) return sendFiles();
    if (!text || sending) return;
    if (!entry.sends) {
      await navigator.clipboard.writeText(text).catch(() => {});
      draft = "";
      notice = tr("Gekopieerd: plak het in {app}.", "Copied: paste it in {app}.", { app });
      return;
    }
    sending = true;
    notice = "";
    draft = "";
    const quoted = replying;
    replying = null;
    try {
      await chatsApi.send(entry.key, text, quoted?.id ?? null);
      whatsapp.version++;
      if (isWhatsApp) await whatsapp.reload();
      else await loadThread();
    } catch (e) {
      notice = tr("Niet verstuurd: {error}", "Not sent: {error}", { error: String(e) });
      if (!draft.trim()) draft = text;
      replying = quoted;
    } finally {
      sending = false;
      field?.focus();
    }
  }

  /** The field's words become your message's new words, after Return or the arrow. */
  async function saveEdit() {
    const target = editing;
    const text = draft.trim();
    if (!target || !text || sending) return;
    sending = true;
    try {
      await chatsApi.message(entry.key, target.id, "edit", text);
      editing = null;
      draft = "";
      await loadThread();
    } catch (e) {
      notice = String(e);
    } finally {
      sending = false;
    }
  }

  // A voice message (`ChatMicButton`, `ChatRecordingBar`): the mic in an empty field records, the bar shows how long,
  // the bin throws it away, the arrow sends it as a voice note (Opus, moved into Ogg in Rust).
  let recording = $state<{ recorder: MediaRecorder; chunks: Blob[]; started: number } | null>(null);
  let elapsed = $state(0);
  async function record() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream, MediaRecorder.isTypeSupported("audio/webm;codecs=opus") ? { mimeType: "audio/webm;codecs=opus" } : undefined);
      const chunks: Blob[] = [];
      recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
      recorder.start(250);
      recording = { recorder, chunks, started: Date.now() };
      elapsed = 0;
    } catch (e) {
      notice = String(e);
    }
  }
  $effect(() => {
    if (!recording) return;
    const timer = setInterval(() => recording && (elapsed = Math.floor((Date.now() - recording.started) / 1000)), 250);
    return () => clearInterval(timer);
  });
  function stopRecording(): Promise<Blob | null> {
    const r = recording;
    recording = null;
    if (!r) return Promise.resolve(null);
    return new Promise((done) => {
      r.recorder.onstop = () => {
        r.recorder.stream.getTracks().forEach((t) => t.stop());
        done(new Blob(r.chunks, { type: r.recorder.mimeType || "audio/webm" }));
      };
      r.recorder.stop();
    });
  }
  async function sendRecording() {
    const blob = await stopRecording();
    if (!blob || !blob.size) return;
    sending = true;
    try {
      const data = new Uint8Array(await blob.arrayBuffer());
      let binary = "";
      for (let i = 0; i < data.length; i += 0x8000) binary += String.fromCharCode(...data.subarray(i, i + 0x8000));
      await chatsApi.sendFile(entry.key, "voice-note.webm", blob.type, btoa(binary), "", replying?.id ?? null, true);
      replying = null;
      whatsapp.version++;
      await loadThread();
    } catch (e) {
      notice = tr("Niet verstuurd: {error}", "Not sent: {error}", { error: String(e) });
    } finally {
      sending = false;
    }
  }
  const clock = (s: number) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

  async function sendFiles() {
    sending = true;
    notice = "";
    const waiting = [...files];
    let caption = draft.trim();
    try {
      while (waiting.length) {
        const file = waiting[0];
        const data = new Uint8Array(await file.arrayBuffer());
        let binary = "";
        for (let i = 0; i < data.length; i += 0x8000) binary += String.fromCharCode(...data.subarray(i, i + 0x8000));
        await chatsApi.sendFile(entry.key, file.name || "file", file.type, btoa(binary), caption, replying?.id ?? null);
        replying = null;
        waiting.shift();
        caption = "";
      }
      draft = "";
      whatsapp.version++;
      await loadThread();
    } catch (e) {
      notice = tr("Niet verstuurd: {error}", "Not sent: {error}", { error: String(e) });
    } finally {
      files = waiting;
      sending = false;
    }
  }

  /// Files go to every chat whose abilities allow outgoing attachments (WhatsApp + connected helper apps).
  const takesFiles = $derived(abilities.send && (abilities.sends?.length ?? 0) > 0);
  const takesVoice = $derived(abilities.send && (abilities.sends ?? []).includes("voice"));
  let picker = $state<HTMLInputElement | null>(null);
  // Which kinds the "+" menu's tile asked the file picker for ("" is any file).
  let pickerAccept = $state("");
  function choose(accept: string) {
    pickerAccept = accept;
    tick().then(() => picker?.click());
  }
  // The panel open above the field (`ChatComposerModel.Panel`): GIFs or stickers.
  let panel = $state<"gifs" | "stickers" | "poll" | null>(null);
  function openPanel(kind: "gifs" | "stickers" | "poll") {
    emojiOpen = false;
    panel = panel === kind ? null : kind;
  }
  /// A GIF picked in the shelf goes at once, as WhatsApp sends one, with what is typed as its caption.
  async function sendGif(name: string, mime: string, base64: string) {
    sending = true;
    notice = "";
    try {
      await chatsApi.sendFile(entry.key, name, mime, base64, draft.trim(), replying?.id ?? null);
      draft = "";
      replying = null;
      whatsapp.version++;
      await loadThread();
    } catch (e) {
      notice = tr("Niet verstuurd: {error}", "Not sent: {error}", { error: String(e) });
      throw e;
    } finally {
      sending = false;
    }
  }
  /// A poll you wrote goes to the chat, where its app takes one (`abilities.polls`).
  async function sendPoll(poll: { question: string; options: string[]; multiple: boolean }) {
    await chatsApi.sendPoll(entry.key, poll);
    whatsapp.version++;
    if (isWhatsApp) await whatsapp.reload();
    await loadThread();
  }
  /// Your vote on a poll in this chat, where its app takes votes (`abilities.vote`).
  async function vote(m: Bubble, choice: string[]) {
    try {
      await chatsApi.vote(entry.key, m.id, choice);
      await loadThread();
    } catch (e) {
      notice = tr("Je stem kon niet worden verstuurd. Probeer het opnieuw of stem in de app.", "Your vote could not be sent. Try again or vote in the app.");
      throw e;
    }
  }
  function openChatOptions() {
    panel = null;
    openChatSettings();
  }
  function addFiles(list: FileList | File[] | null | undefined) {
    if (!list || !takesFiles) return;
    files = [...files, ...Array.from(list)].slice(0, 10);
  }
  function paste(e: ClipboardEvent) {
    const pasted = Array.from(e.clipboardData?.files ?? []);
    if (pasted.length && takesFiles) {
      e.preventDefault();
      addFiles(pasted);
    }
  }
  let dragging = $state(false);

  // The smiley beside the field (`ChatEmojiButton`): your most used emoji first, then a common set.
  let emojiOpen = $state(false);
  const emojiList = $derived(emojiOpen ? [...new Set([...frequentEmoji(), ...COMMON_EMOJI])] : []);
  function putEmoji(e: string) {
    usedEmoji(e);
    const at = field?.selectionStart ?? draft.length;
    draft = draft.slice(0, at) + e + draft.slice(field?.selectionEnd ?? at);
    emojiOpen = false;
    tick().then(() => { field?.focus(); field?.setSelectionRange(at + e.length, at + e.length); });
  }

  // "@" in a group lists its people (`ChatTags`): a click puts "@Name " in the field and its app tags them.
  let caret = $state(0);
  const tagging = $derived(abilities.send ? typingTag(draft.slice(0, caret)) : null);
  const tagMatches = $derived(tagging === null || !isGroup ? [] : people.filter((p) => p.toLowerCase().startsWith(tagging.toLowerCase())).slice(0, 6));
  /// "@" offers "@nook" first, at the start of the field (`ChatDraft.choices`).
  const offersNook = $derived(tagging !== null && "nook".startsWith(tagging.toLowerCase()) && draft.slice(0, caret).trim().startsWith("@"));
  function tagPerson(name: string) {
    const before = insertTag(draft.slice(0, caret), name);
    draft = before + draft.slice(caret);
    caret = before.length;
    tick().then(() => { field?.focus(); field?.setSelectionRange(caret, caret); });
  }

  let infoAt = $state<DOMRect | null>(null);
  // An edited (or deleted) message's earlier words (`MessageVersionsView`): what it said until when, and now.
  let versionsOf = $state<{ m: Bubble; anchor: DOMRect } | null>(null);
  const versionRows = $derived.by<MenuItem[][]>(() => {
    if (!versionsOf) return [];
    const m = versionsOf.m;
    const rows: MenuItem[] = m.versions.map((v) => ({ label: v.text, detail: tr("Tot {time}", "Until {time}", { time: dayLabel(new Date(v.replaced), new Date()) + " " + time(v.replaced) }) }));
    if (!rows.length) rows.push({ label: tr("Nook heeft geen eerdere tekst van dit bericht: het veranderde voordat Nook het had.", "Nook has no earlier text of this message: it changed before Nook had it.") });
    if (!m.deleted) rows.push({ label: m.text, detail: tr("Nu", "Now") });
    return [rows];
  });
  // What Nook could do for what was just said (`ChatActionSuggestion`): the chat's newest message, yours as well, and
  // its newest thirty lines, you as "You" and everyone else by name.
  const suggestionTurn = $derived.by<SuggestionTurn | null>(() => {
    const last = bubbles[bubbles.length - 1];
    return last ? { conversation: entry.key, message: last.id, date: last.date } : null;
  });
  const suggestionLines = (): SuggestionLine[] =>
    bubbles.filter((b) => !b.deleted).slice(-30).map((b) => ({ speaker: b.fromMe ? tr("Jij", "You") : b.sender || entry.name, text: b.text || fileLabel(b.media) || "", id: b.id }));
  // Forwarding a message (`ChatForward`, CH-48): to every chat whose capabilities accept the text/attachment.
  let forwarding = $state<Bubble | null>(null);
  function canForwardMessage(m: Bubble): boolean {
    if (m.deleted) return false;
    const kind = outgoingKindOfMedia(m.media);
    if (!m.text.trim() && !kind) return false;
    return targets.some((t) => t.key !== entry.key && canForwardTo(t, m.text, kind));
  }
  // Deleting a message asks how (`chat.delete.choose`).
  let deleting = $state<Bubble | null>(null);
  async function step(m: Bubble, what: "revoke" | "deleteForMe" | "react", text?: string) {
    try {
      await chatsApi.message(entry.key, m.id, what, text);
      if (what === "react" && text) usedEmoji(text);
      await loadThread();
    } catch (e) {
      notice = String(e);
    }
  }

  async function nook() {
    if (isWhatsApp) {
      const id = await whatsapp.askNook();
      if (id) onnook(id);
      return;
    }
    try {
      const id = await invokeOrFallback<string | null>(
        "chat_ask_nook",
        { key: entry.key },
        async () => {
          await writeWithNook("");
          return null;
        },
      );
      if (id) onnook(id);
    } catch (e) {
      notice = String(e);
    }
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Tab" && !e.shiftKey && ghost) {
      e.preventDefault();
      draft = ghost;
      return;
    }
    if (e.key === "Escape" && ghost) {
      e.preventDefault();
      suggestion = null;
      return;
    }
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send();
    } else if (e.key === "Escape") {
      e.preventDefault();
      if (emojiOpen) emojiOpen = false;
      else if (files.length) files = [];
      else if (editing) { editing = null; draft = ""; }
      else if (replying) replying = null;
      else if (!draft) onclose();
    } else if (e.key === "ArrowUp" && !draft && abilities.edit) {
      // Arrow up in an empty field changes your last message, as the chat apps have it.
      const last = [...bubbles].reverse().find((b) => b.fromMe && !b.deleted && b.text);
      if (last) { e.preventDefault(); startEdit(last); }
    }
  }
  function startEdit(m: Bubble) {
    replying = null;
    editing = m;
    draft = m.text;
    tick().then(() => field?.focus());
  }

  // Sound plays in the chat itself: fetched on the first click, then handed to a player (WhatsApp's voice notes).
  let sounds = $state<Record<string, string>>({});
  let loadingSound = $state<string | null>(null);
  async function listen(m: Bubble) {
    if (sounds[m.id] || loadingSound) return;
    loadingSound = m.id;
    try {
      const { mime, base64 } = await connectorsApi.whatsappAudio(entry.id, m.id);
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      sounds[m.id] = URL.createObjectURL(new Blob([bytes], { type: mime }));
    } catch (e) {
      notice = String(e);
    } finally {
      loadingSound = null;
    }
  }
  const isSound = (m: Bubble) => m.media.kind === "voice" || m.media.kind === "audio";
  const photo = (m: Bubble) => (isWhatsApp && m.media.kind === "image" ? whatsapp.card?.previews[m.id]?.image ?? null : null);
  const textOf = (m: Bubble) => bubbleText({ ...m, chat: entry.id, senderName: m.sender, media: m.media });

  // The "…" menu: Nook's answer where Nook can write it, then the chat's own steps respecting ChatAbilities.
  let menuAnchor = $state<DOMRect | null>(null);
  const menu = $derived<MenuItem[][]>([
    ...(abilities.send ? [[{ label: tr("Laat Nook antwoorden", "Let Nook reply"), icon: "sparkles", onselect: nook }]] : []),
    ...chatMenu(entry, onclose),
  ]);

  // A message's menu, from the chevron on it or a right-click (`MessageMenuItems`): the quick reactions on top, then
  // reply, forward, copy, and for your own message info, edit and delete, all respecting `ChatAbilities`.
  let messageMenu = $state<{ m: Bubble; anchor: DOMRect } | null>(null);
  let receiptInfo = $state<{ m: Bubble; anchor: DOMRect } | null>(null);
  function openMessageInfo(e: MouseEvent, m: Bubble) {
    e.stopPropagation();
    receiptInfo = { m, anchor: (e.currentTarget as HTMLElement).getBoundingClientRect() };
  }
  const messageItems = $derived.by<MenuItem[][]>(() => {
    if (!messageMenu) return [];
    const m = messageMenu.m;
    const anchor = messageMenu.anchor;
    return [
      [
        ...(abilities.reply && !m.deleted ? [{ label: tr("Beantwoorden", "Reply"), icon: "reply", onselect: () => quote(m) }] : []),
        ...(canForwardMessage(m) ? [{ label: tr("Doorsturen", "Forward"), icon: "forward", onselect: () => (forwarding = m) }] : []),
        ...(m.text ? [{ label: tr("Kopieer", "Copy"), icon: "copy", onselect: () => navigator.clipboard.writeText(m.text).catch(() => {}) }] : []),
        ...(m.fromMe && !m.deleted ? [{ label: tr("Berichtinfo", "Message info"), icon: "info", onselect: () => (receiptInfo = { m, anchor }) }] : []),
      ],
      [
        ...(abilities.edit && m.fromMe && !m.deleted && m.text ? [{ label: tr("Bewerken", "Edit"), icon: "pencil", onselect: () => startEdit(m) }] : []),
        ...(!m.deleted ? [{ label: tr("Verwijderen…", "Delete…"), icon: "trash-2", destructive: true, onselect: () => (deleting = m) }] : []),
      ],
    ].filter((s) => s.length);
  });
  const messageReactions = $derived(messageMenu && abilities.react && !messageMenu.m.deleted ? {
    emoji: QUICK_REACTIONS,
    mine: messageMenu.m.reactions.filter((r) => r.mine).map((r) => r.emoji),
    onpick: (e: string) => { const m = messageMenu!.m; step(m, "react", m.reactions.some((r) => r.mine && r.emoji === e) ? "" : e); },
  } : undefined);
  function quote(m: Bubble) {
    editing = null;
    replying = m;
    tick().then(() => field?.focus());
  }
  function openMessageMenu(e: MouseEvent, m: Bubble) {
    e.preventDefault();
    const at = e.type === "contextmenu" ? new DOMRect(e.clientX, e.clientY, 0, 0) : (e.currentTarget as HTMLElement).getBoundingClientRect();
    messageMenu = { m, anchor: at };
  }

  /// "Don't show for this app again" on the line that says what Nook cannot do here (`ChatLimitsLine`).
  const LIMITS = "chats.limitsHidden";
  let limitsHidden = $state<string[]>((() => { try { return JSON.parse(localStorage.getItem(LIMITS) ?? "[]"); } catch { return []; } })());
  function hideLimits() {
    limitsHidden = [...limitsHidden, entry.app];
    try { localStorage.setItem(LIMITS, JSON.stringify(limitsHidden)); } catch { /* until the window closes */ }
  }
  const quoteSender = (m: Bubble) => (m.fromMe ? tr("Jij", "You") : m.sender || entry.name);
  const receiptNow = $derived.by(() => {
    void bubbles;
    void receiptInfo;
    return new Date();
  });
  $effect(() => {
    if (!receiptInfo) return;
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); receiptInfo = null; } };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });
</script>

<div class="detail">
  <header class="head" data-tauri-drag-region>
    <!-- The face and the name open the chat's info, as in a chat app. -->
    <button class="face" title={tr("Toon info", "Show info")} aria-label={tr("Toon info", "Show info")} onclick={(e) => (infoAt = (e.currentTarget as HTMLElement).getBoundingClientRect())}><ChatFace id={entry.id} app={entry.app} name={entry.name} size={36} /></button>
    <div class="who">
      <button class="name" title={entry.name} onclick={(e) => (infoAt = (e.currentTarget as HTMLElement).getBoundingClientRect())}>{entry.name}</button>
      <span class="sub">
        {#if typingText}
          <span class="typing-head">{typingText}</span>
        {:else}
          <span>{app}</span>
          {#if isGroup}
            <span class="dot" aria-hidden="true">·</span>
            <span title={people.join(", ")}>{people.length ? tr("{n} leden", "{n} members", { n: people.length }) : tr("Groep", "Group")}</span>
          {/if}
          {#if isChatPinned(entry)}
            <span class="dot" aria-hidden="true">·</span>
            <span class="status-mark" title={tr("Vastgezet", "Pinned")}><Ico name="pin" size={11} stroke={2.4} /></span>
          {/if}
          {#if isChatMuted(entry)}
            <span class="dot" aria-hidden="true">·</span>
            <span class="status-mark" title={tr("Gedempt", "Muted")}><Ico name="bell-off" size={11} stroke={2.4} /></span>
          {/if}
          {#if isChatArchived(entry)}
            <span class="dot" aria-hidden="true">·</span>
            <span class="status-mark" title={tr("Gearchiveerd", "Archived")}><Ico name="archive" size={11} stroke={2.4} /></span>
          {/if}
          {#if entry.read !== "unread" && !entry.lastIsMine && bubbles.length}
            <span class="dot" aria-hidden="true">·</span>
            <span>{entry.read === "readInNook" ? tr("Gelezen in Nook", "Read in Nook") : tr("Gelezen", "Read")}</span>
          {/if}
        {/if}
      </span>
    </div>
    <span class="spacer"></span>
    {#if canCallChat(entry.app, isGroup)}
      <IconButton title={tr("Spraakoproep", "Voice call")} size={24} onclick={() => activeCall.start(entry, "voice")}><CallIcon name="phone" size={14} /></IconButton>
      <IconButton title={tr("Videogesprek", "Video call")} size={24} onclick={() => activeCall.start(entry, "video")}><CallIcon name="video" size={14} /></IconButton>
    {/if}
    <IconButton title={tr("Open {app}", "Open {app}", { app })} size={24} onclick={() => activeCall.openApp(entry.app)}><Ico name="external-link" size={14} /></IconButton>
    <IconButton title={tr("Meer acties", "More actions")} size={24} onclick={(e) => (menuAnchor = (e.currentTarget as HTMLElement).getBoundingClientRect())}><Ico name="ellipsis" size={14} stroke={2.4} /></IconButton>
  </header>

  <div class="transcript" bind:this={scroller} onscroll={scrolled}>
    <!-- The messages sit at the bottom, as a chat app's do; the room above them stays empty. -->
    <div class="fill" aria-hidden="true"></div>
    {#if hasOlder && bubbles.length}<TimelineEarlierRow loading={loadingOlder} onshow={older} />{/if}
    {#if !bubbles.length}
      <div class="empty">
        <ChatFace id={entry.id} app={entry.app} name={entry.name} size={56} badge={false} />
        <strong>{entry.name}</strong>
        <p>{tr("Nog geen berichten hier. Nieuwe berichten uit {app} komen vanzelf binnen.", "No messages here yet. New ones from {app} come in by themselves.", { app })}</p>
      </div>
    {/if}
    {#each lines as line (line.kind === "day" ? line.id : line.m.id)}
      {#if line.kind === "day"}
        <div class="day"><span>{line.label}</span></div>
      {:else if line.kind === "notice"}
        <div class="notice-line" data-message-id={line.m.id}><span title={time(line.m.date)}>{line.text}</span></div>
      {:else}
        {@const m = line.m}
        {@const file = m.deleted ? null : fileLabel(m.media)}
        {@const image = photo(m)}
        {@const call = !m.deleted && !file ? callOf(m.text) : null}
        {@const text = m.deleted || call ? "" : file ? m.text : textOf(m)}
        {@const link = text ? firstLink(text) : null}
        {@const answered = m.replyTo ? byId.get(m.replyTo) : undefined}
        {@const forwardable = canForwardMessage(m)}
        {@const receiptTip = m.fromMe && !m.deleted ? readReceiptSummary(m, isGroup, receiptNow) : null}
        {@const showReceiptFoot = m.fromMe && !m.deleted && m.id === lastMineId && !!receiptTip && ((isGroup && (m.readBy?.length ?? 0) > 0) || (!isGroup && m.receipt === "read" && !!m.readAt))}
        {#if m.id === newFrom && m.id !== bubbles[0]?.id}
          <!-- Where what came in since you last looked begins (`ChatNewDivider`). -->
          <div class="new-divider"><span>{tr("Nieuwe berichten", "New messages")}</span></div>
        {/if}
        <!-- The message's id and its chat's key, so a selection in the chat can carry where it came from (BR-62). -->
        <div class="line" class:mine={m.fromMe} class:first={line.first} class:reacted={m.reactions.length > 0 || showReceiptFoot} data-chat-key={entry.key} data-message-id={m.id} data-sender={m.fromMe ? "" : m.sender || entry.name}>
          {#if isGroup && !m.fromMe && m.sender}
            <!-- In a group, who wrote it shows beside the first message of their run (`ChatSenderFace`); the rest keeps the room. -->
            <span class="sender-face">{#if line.first}<ChatFace id={m.sender} app={entry.app} name={m.sender} size={28} badge={false} />{/if}</span>
          {/if}
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <div class="bubble" class:mine={m.fromMe} class:tailed={line.first} class:joins={!line.last} class:bare={!!image && !text}
            oncontextmenu={(e) => openMessageMenu(e, m)}>
            {#if line.first && isGroup && !m.fromMe && m.sender}<span class="sender" style:color={personTint(m.sender)}>{m.sender}</span>{/if}
            {#if answered && !m.deleted}
              <ChatQuote sender={answered.fromMe ? tr("Jij", "You") : answered.sender || entry.name} text={answered.deleted ? tr("Dit bericht is verwijderd", "This message was deleted") : answered.text || fileLabel(answered.media) || ""} mine={answered.fromMe} />
            {/if}
            {#if m.deleted}
              <span class="deleted"><Ico name="ban" size={13} />{tr("Dit bericht is verwijderd", "This message was deleted")}</span>
            {:else if image}
              <button class="photo" title={tr("Groot bekijken", "View larger")} onclick={() => (whatsapp.enlarged = m.id)}><img src={image} alt={file ?? tr("Foto", "Photo")} /></button>
            {:else if file}
              <div class="file">
                <Ico name={m.media.kind === "video" ? "play" : m.media.kind === "document" ? "file" : m.media.kind === "image" ? "image" : "mic"} size={15} />
                <span class="file-name">{file}</span>
                {#if isWhatsApp}
                  {#if isSound(m)}
                    {#if sounds[m.id]}
                      <!-- svelte-ignore a11y_media_has_caption -->
                      <audio controls autoplay src={sounds[m.id]}></audio>
                    {:else}
                      <button class="small" onclick={() => listen(m)} disabled={loadingSound === m.id}>{loadingSound === m.id ? tr("Laden…", "Loading…") : tr("Afspelen", "Play")}</button>
                    {/if}
                  {:else}
                    <button class="small" onclick={() => whatsapp.open(m.id, file)}>{m.media.kind === "video" ? tr("Video afspelen", "Play video") : tr("Openen", "Open")}</button>
                  {/if}
                {/if}
              </div>
            {/if}
            {#if call}
              <!-- A call its app noted (`ChatCallRow`): what kind, who rang and how long, with the time beside it. -->
              {@const mine = call.outgoing ?? m.fromMe}
              {@const missedHere = call.missed && !mine}
              <span class="call">
                <span class="call-mark" class:missed={missedHere} class:quiet={call.missed && !missedHere}><Ico name={missedHere ? (call.video ? "video-off" : "phone-off") : call.video ? "video" : mine ? "phone-outgoing" : "phone-incoming"} size={16} stroke={2.4} /></span>
                <span class="call-words"><span class="call-title" class:missed={missedHere}>{callTitle(call, m.fromMe)}</span><span class="call-detail">{callDetail(call, m.fromMe)}</span></span>
              </span>
            {/if}
            {#if m.poll && !m.deleted}<ChatPollView poll={m.poll} onvote={abilities.vote ? (choice) => vote(m, choice) : undefined} />{/if}
            {#if link}<LinkCard url={link} />{/if}
            <span class="body">
              {#if text}<span class="text">{text}</span>{/if}
              {#if line.last || call || m.fromMe}
                <span class="stamp">
                  {#if m.edited || (m.deleted && m.versions.length)}
                    <button class="edited" title={tr("Wat er eerder stond", "What it said before")} onclick={(e) => (versionsOf = { m, anchor: (e.currentTarget as HTMLElement).getBoundingClientRect() })}>{m.edited ? tr("Bewerkt", "Edited") : ""}{#if m.deleted}<Ico name="history" size={11} />{/if}</button>
                  {/if}
                  {time(m.date)}{#if m.fromMe && !m.deleted}<Ticks receipt={m.receipt} size={12} detail={receiptTip} onclick={(e) => openMessageInfo(e, m)} />{/if}
                </span>
              {/if}
            </span>
            {#if !m.deleted && (abilities.send || m.text || forwardable)}
              <span class="bubble-actions">
                {#if forwardable}
                  <button class="bubble-action" title={tr("Doorsturen", "Forward")} aria-label={tr("Doorsturen", "Forward")} onclick={(e) => { e.stopPropagation(); forwarding = m; }}><Ico name="forward" size={12} stroke={2.4} /></button>
                {/if}
                <button class="bubble-action" title={tr("Meer acties", "More actions")} aria-label={tr("Meer acties", "More actions")} onclick={(e) => openMessageMenu(e, m)}><Ico name="chevron-down" size={12} stroke={2.4} /></button>
              </span>
            {/if}
          </div>
          {#if m.reactions.length}
            <div class="reactions"><ReactionChips reactions={m.reactions} onreact={abilities.react ? (e) => step(m, "react", e) : undefined} /></div>
          {/if}
          {#if showReceiptFoot && receiptTip}
            <div class="receipt-foot">
              <button type="button" class="receipt-link" onclick={(e) => openMessageInfo(e, m)}>{receiptTip}</button>
            </div>
          {/if}
        </div>
      {/if}
    {/each}
    {#if typingText}
      <!-- Someone is typing right now (`ChatTypingBubble` on the Mac). -->
      <div class="line first typing-row" role="status" aria-live="polite">
        <div class="bubble tailed typing-bubble">
          <span class="typing-dots" aria-hidden="true"><span></span><span></span><span></span></span>
          <span class="typing-label">{typingText}</span>
        </div>
      </div>
    {/if}
  </div>

  <footer class="foot">
    {#if notice || whatsapp.notice}<p class="notice">{notice || whatsapp.notice}</p>{/if}
    <ActionSuggestionBar turn={suggestionTurn} busy={sending} place={{ kind: "chat", app, name: entry.name }} lines={suggestionLines} />
    {#if entry.read === "unread"}
      <!-- Something new sits in the tray above the box (`ChatReadLine`): how much, and reading it. Once read in Nook,
           where it stands moves to the header and the tray holds what Nook cannot do here, if anything. -->
      <div class="tray ctray">
        <CountBadge count={entry.unread} />
        <span class="tray-line">{tr("{n} nieuw", "{n} new", { n: entry.unread })}</span>
        <span class="spacer"></span>
        {#if !isWhatsApp}<button class="mark" onclick={() => markReadInNook(entry)}><Ico name="check" size={12} stroke={2.8} />{tr("Gelezen in Nook", "Read in Nook")}</button>{/if}
        {#if abilities.markRead}<button class="mark" onclick={() => markReadInApp(entry)}><span class="mint"><Ico name="check-check" size={12} stroke={2.8} /></span>{tr("Markeer gelezen in {app}", "Mark as read in {app}", { app })}</button>{/if}
      </div>
    {:else if !abilities.send && !limitsHidden.includes(entry.app)}
      <!-- What Nook cannot do in this chat, and the one step that brings it (`ChatLimitsLine`). -->
      <div class="tray ctray">
        <span class="amber"><Ico name="eye" size={13} stroke={2.4} /></span>
        <span class="tray-line wrap">{tr("Nook leest {app} hier alleen mee: versturen, emoji, bewerken en je vinkjes werken pas als je {app} koppelt.", "Nook only reads {app} here: sending, emoji, editing and your ticks work once you link {app}.", { app })}</span>
        <button class="small-ghost" onclick={openChatSettings}>{tr("Koppel {app}", "Link {app}", { app })}</button>
        <IconButton title={tr("Niet meer tonen voor deze app", "Don't show for this app again")} size={20} onclick={hideLimits}><Ico name="x" size={11} stroke={2.4} /></IconButton>
      </div>
    {/if}
    {#if editing}
      <div class="ctray full"><ChatQuote sender={tr("Bericht bewerken", "Editing message")} text={editing.text} mine={true}>
        {#snippet trailing()}<IconButton title={tr("Annuleer", "Cancel")} size={20} onclick={() => { editing = null; draft = ""; }}><Ico name="x" size={11} stroke={2.4} /></IconButton>{/snippet}
      </ChatQuote></div>
    {:else if replying}
      <div class="ctray full"><ChatQuote sender={tr("Antwoord aan {name}", "Replying to {name}", { name: quoteSender(replying) })} text={replying.text || fileLabel(replying.media) || ""} mine={replying.fromMe}>
        {#snippet trailing()}<IconButton title={tr("Annuleer", "Cancel")} size={20} onclick={() => (replying = null)}><Ico name="x" size={11} stroke={2.4} /></IconButton>{/snippet}
      </ChatQuote></div>
    {/if}
    {#if files.length}
      <!-- What waits to go with the next send (`ChatAttachmentReview`). -->
      <div class="files">
        {#each files as f, i (i)}
          <span class="chip"><Ico name={f.type.startsWith("image/") ? "image" : f.type.startsWith("video/") ? "play" : "file"} size={12} /><span class="chip-name">{f.name}</span>
            <button class="chip-x" aria-label={tr("Verwijder", "Remove")} onclick={() => (files = files.filter((_, j) => j !== i))}><Ico name="x" size={10} stroke={2.6} /></button></span>
        {/each}
      </div>
    {/if}
    {#if tagMatches.length || offersNook}
      <!-- "@nook" and the group's people whose name fits what follows the "@" (`ChatTags`). -->
      <div class="tags" role="listbox">
        {#if offersNook}
          <button role="option" aria-selected="false" class="tag nook" onmousedown={(e) => { e.preventDefault(); draft = "@nook " + draft.slice(caret).trimStart(); caret = 6; tick().then(() => { field?.focus(); field?.setSelectionRange(6, 6); }); }}>
            <span class="nook-mark"><Ico name="sparkles" size={12} stroke={2.4} /></span>
            <span class="tag-words"><span>@nook</span><span class="tag-detail">{tr("Schrijft je bericht en zoekt zo nodig in je mail, agenda en chats", "Writes your message, looking in your mail, calendar and chats if needed")}</span></span>
          </button>
        {/if}
        {#each tagMatches as p (p)}
          <button role="option" aria-selected="false" class="tag" onmousedown={(e) => { e.preventDefault(); tagPerson(p); }}><ChatFace id={p} app={entry.app} name={p} size={20} badge={false} />{p}</button>
        {/each}
      </div>
    {/if}
    {#if panel === "gifs" || panel === "stickers"}
      <ChatGifShelf kind={panel} onsend={sendGif} onfile={addFiles} onclose={() => (panel = null)} onsettings={openChatOptions} />
    {:else if panel === "poll"}
      <ChatPollForm onsend={sendPoll} onclose={() => (panel = null)} />
    {/if}
    {#if emojiOpen}
      <div class="emoji-grid" role="listbox" aria-label={tr("Emoji", "Emoji")}>
        {#each emojiList as e (e)}<button class="emoji" role="option" aria-selected="false" onclick={() => putEmoji(e)}>{e}</button>{/each}
      </div>
    {/if}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="box" class:dragging ondragover={(e) => { if (takesFiles && e.dataTransfer?.types.includes("Files")) { e.preventDefault(); dragging = true; } }}
      ondragleave={() => (dragging = false)} ondrop={(e) => { e.preventDefault(); dragging = false; addFiles(e.dataTransfer?.files); }}>
      {#if abilities.send}
        <div class="leading" class:hidden={!!recording}>
          {#if takesFiles}
            <!-- "+" (`ChatAttachMenu`, `ChatAttachPanel`): the kinds of file as tiles, the panels below them. -->
            <Dropdown width={280} label={tr("Toevoegen", "Attach")}>
              {#snippet trigger({ toggle, open })}
                <IconButton title={tr("Toevoegen", "Attach")} size={28} onclick={toggle}><Ico name="plus" size={15} stroke={2.2} /></IconButton>
              {/snippet}
              {#snippet children({ close })}
                <div class="dd-header">{tr("Toevoegen aan je bericht", "Add to your message")}</div>
                <DropdownTileGrid
                  note={tr("Of sleep bestanden op de chat (hooguit {n})", "Or drop files on the chat (up to {n})", { n: 10 })}
                  tiles={[
                    { id: "media", icon: "image", label: tr("Foto & video", "Photo & video"), onselect: () => { close(); choose("image/*,video/*"); } },
                    { id: "file", icon: "file", label: tr("Bestand", "File"), onselect: () => { close(); choose(""); } },
                    { id: "audio", icon: "file-audio", label: tr("Audio", "Audio"), onselect: () => { close(); choose("audio/*"); } },
                    { id: "gif", icon: "file-video", label: tr("GIF", "GIF"), onselect: () => { close(); openPanel("gifs"); } },
                    { id: "stickers", icon: "smile", label: tr("Stickers", "Stickers"), onselect: () => { close(); openPanel("stickers"); } },
                  ]}
                />
                {#if abilities.polls}
                  <div class="dd-header">{tr("Delen", "Share")}</div>
                  <DropdownRow symbol="chart-column" title={tr("Peiling", "Poll")} detail={tr("Stel een vraag met keuzes", "Ask a question with choices")} onclick={() => { close(); openPanel("poll"); }} />
                {/if}
              {/snippet}
            </Dropdown>
            <input class="hidden" type="file" multiple accept={pickerAccept} bind:this={picker} onchange={(e) => { addFiles((e.currentTarget as HTMLInputElement).files); (e.currentTarget as HTMLInputElement).value = ""; }} />
          {/if}
          <IconButton title={tr("Emoji", "Emoji")} size={28} onclick={() => (emojiOpen = !emojiOpen)}><Ico name="smile" size={15} stroke={2} /></IconButton>
        </div>
      {/if}
      <textarea class:hidden={!!recording} bind:this={field} rows="1" bind:value={draft} onkeydown={keydown} onpaste={paste}
        onkeyup={() => (caret = field?.selectionStart ?? draft.length)} onclick={() => (caret = field?.selectionStart ?? draft.length)} oninput={() => (caret = field?.selectionStart ?? draft.length)} aria-label={tr("Bericht aan {name}", "Message {name}", { name: entry.name })}
        placeholder={writing ? tr("Nook schrijft je bericht…", "Nook is writing your message…") : ghost ?? tr("Bericht aan {name} · @nook schrijft mee", "Message {name} · @nook helps you write", { name: entry.name })}
        disabled={writing} title={ghost ? tr("Tab zet dit antwoord in het veld", "Tab puts this answer in the field") : undefined}></textarea>
      {#if recording}
        <span class="recording" aria-label={tr("Spraakbericht wordt opgenomen", "Recording a voice message")}><span class="rec-dot"></span>{clock(elapsed)}</span>
        <IconButton title={tr("Opname weggooien", "Discard recording")} size={28} onclick={() => stopRecording()}><Ico name="trash-2" size={14} /></IconButton>
        <button class="send ready" title={tr("Verstuur", "Send")} aria-label={tr("Verstuur", "Send")} onclick={sendRecording}><Ico name="arrow-up" size={15} stroke={2.6} /></button>
      {:else if takesVoice && !draft.trim() && !files.length && !editing}
        <button class="send" title={tr("Spraakbericht opnemen", "Record a voice message")} aria-label={tr("Spraakbericht opnemen", "Record a voice message")} onclick={record} disabled={sending}><Ico name="mic" size={15} stroke={2.4} /></button>
      {:else}
      <button class="send" class:ready disabled={!ready} title={abilities.send ? tr("Verstuur", "Send") : tr("Kopieer voor {app}", "Copy for {app}", { app })} aria-label={abilities.send ? tr("Verstuur", "Send") : tr("Kopieer voor {app}", "Copy for {app}", { app })} onclick={send}><Ico name={abilities.send ? "arrow-up" : "copy"} size={15} stroke={2.6} /></button>
      {/if}
    </div>
  </footer>
</div>

{#if menuAnchor}<Menu sections={menu} anchor={menuAnchor} onclose={() => (menuAnchor = null)} />{/if}
{#if messageMenu && (messageItems.length || messageReactions)}<Menu sections={messageItems} reactions={messageReactions} anchor={messageMenu.anchor} onclose={() => (messageMenu = null)} />{/if}
{#if versionsOf}<Menu title={versionsOf.m.deleted ? tr("Voordat het werd verwijderd", "Before it was deleted") : tr("Eerdere versies", "Earlier versions")} sections={versionRows} anchor={versionsOf.anchor} onclose={() => (versionsOf = null)} />{/if}
{#if infoAt}<ChatInfo {entry} {people} profile={thread?.profile} bubbles={bubbles} {onopenchat} anchor={infoAt} onclose={() => (infoAt = null)} onclosechat={onclose} />{/if}
<ChatCallCard />
{#if forwarding}<ChatForwardSheet sourceKey={entry.key} messageId={forwarding.id} targets={targets} sender={forwarding.fromMe ? tr("Jij", "You") : forwarding.sender || entry.name} text={forwarding.text} media={forwarding.media} onclose={() => (forwarding = null)} />{/if}
{#if deleting}
  {@const m = deleting}
  <Dialog title={tr("Bericht verwijderen?", "Delete message?")}
    message={m.fromMe && abilities.delete ? tr("Voor iedereen verdwijnt het ook in {app}; voor jou alleen in Nook.", "For everyone it goes in {app} too; for you only in Nook.", { app }) : abilities.deleteForMe ? tr("Het verdwijnt voor jou in Nook en {app}.", "It goes for you in Nook and {app}.", { app }) : tr("Het verdwijnt alleen in Nook.", "It goes only in Nook.")}
    buttons={[
      ...(m.fromMe && abilities.delete ? [{ label: tr("Verwijderen voor iedereen", "Delete for everyone"), destructive: true, bold: true, onselect: () => step(m, "revoke") }] : []),
      { label: tr("Verwijderen voor mij", "Delete for me"), destructive: true, onselect: () => step(m, "deleteForMe") },
      { label: tr("Annuleer", "Cancel"), onselect: () => {} },
    ]}
    onclose={() => (deleting = null)} />
{/if}
{#if enlarged}<ImageModal src={enlarged} alt={tr("Foto", "Photo")} onclose={() => (whatsapp.enlarged = null)} onopen={() => whatsapp.enlarged && whatsapp.open(whatsapp.enlarged, tr("Foto", "Photo"))} />{/if}
{#if receiptInfo}
  {@const m = receiptInfo.m}
  {@const readReaders = (m.readers ?? []).filter((r) => r.receipt === "read")}
  {@const deliveredReaders = (m.readers ?? []).filter((r) => r.receipt === "delivered")}
  {@const popTop = Math.min(Math.max(12, receiptInfo.anchor.bottom + 6), Math.max(12, window.innerHeight - 280))}
  {@const popLeft = Math.min(Math.max(12, receiptInfo.anchor.right - 260), Math.max(12, window.innerWidth - 284))}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="info-scrim" onclick={() => (receiptInfo = null)}>
    <div class="info-pop" role="dialog" aria-label={tr("Berichtinfo", "Message info")} tabindex="-1"
      style:top="{popTop}px" style:left="{popLeft}px" onclick={(e) => e.stopPropagation()}>
      <div class="info-head">
        <strong>{tr("Berichtinfo", "Message info")}</strong>
        <IconButton title={tr("Sluiten", "Close")} size={20} onclick={() => (receiptInfo = null)}><Ico name="x" size={12} stroke={2.4} /></IconButton>
      </div>
      <div class="info-row">
        <span class="info-key">{tr("Verstuurd", "Sent")}</span>
        <span class="info-val">{dayAndClock(m.date, receiptNow)}</span>
      </div>
      {#if !isGroup}
        <div class="info-row">
          <span class="info-key">
            <Ticks receipt={m.receipt} size={12} />
            {m.receipt === "read" ? tr("Gelezen", "Read") : m.receipt === "delivered" ? tr("Bezorgd", "Delivered") : m.receipt === "pending" ? tr("Versturen…", "Sending…") : m.receipt === "failed" ? tr("Niet verstuurd", "Not sent") : tr("Verstuurd", "Sent")}
          </span>
          <span class="info-val">{m.receipt === "read" && m.readAt ? dayAndClock(m.readAt, receiptNow) : "—"}</span>
        </div>
      {:else}
        {#if readReaders.length}
          <div class="info-group">
            <span class="info-label"><Ticks receipt="read" size={12} />{tr("Gelezen door", "Read by")}</span>
            {#each readReaders as r (r.name)}
              <div class="info-person">
                <span class="info-name">{r.name}</span>
                {#if r.date}<span class="info-val">{dayAndClock(r.date, receiptNow)}</span>{/if}
              </div>
            {/each}
          </div>
        {/if}
        {#if deliveredReaders.length}
          <div class="info-group">
            <span class="info-label"><Ticks receipt="delivered" size={12} />{tr("Bezorgd bij", "Delivered to")}</span>
            {#each deliveredReaders as r (r.name)}
              <div class="info-person">
                <span class="info-name">{r.name}</span>
                {#if r.date}<span class="info-val">{dayAndClock(r.date, receiptNow)}</span>{/if}
              </div>
            {/each}
          </div>
        {/if}
        {#if !readReaders.length && !deliveredReaders.length}
          <div class="info-empty">{tr("Nog geen leesbevestigingen.", "No read receipts yet.")}</div>
        {/if}
      {/if}
    </div>
  </div>
{/if}

<style>
  .detail { height: 100%; min-height: 0; display: flex; flex-direction: column; }
  /* The top row of the window: it moves the window, and keeps clear of the window's buttons on Windows. */
  .head { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-12) calc(var(--space-12) + var(--caption-room, 0px)) var(--space-8) 0; border-bottom: 1px solid var(--hairline); flex: none; }
  .who { min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .face { padding: 0; border: 0; background: none; border-radius: 50%; flex: none; display: inline-flex; }
  .face:hover:not(:disabled) { background: none; border: 0; }
  .name { padding: 0; border: 0; background: none; text-align: left; font: var(--text-title); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .name:hover:not(:disabled) { background: none; border: 0; text-decoration: underline; }
  .sub { display: flex; align-items: center; gap: var(--space-4); font: var(--text-detail); color: var(--text3); white-space: nowrap; overflow: hidden; }
  .status-mark { display: inline-flex; align-items: center; color: var(--text3); }
  .typing-head { color: var(--mint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .spacer { flex: 1; }

  .transcript { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; padding: var(--space-8) var(--space-4); }
  .empty { display: flex; flex-direction: column; align-items: center; gap: var(--space-6); padding-top: var(--space-32); text-align: center; }
  .empty strong { font: var(--text-title); color: var(--paper); }
  .empty p { margin: 0; font: var(--text-detail); color: var(--text3); max-width: 320px; }
  /* A day's line between the messages (`ChatDayDivider`). */
  .fill { flex: 1 0 auto; }
  /* `ChatNewDivider`: an amber line with "New messages" in it. */
  .new-divider { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-4) 0; font: var(--text-caption); color: var(--amber); }
  .new-divider::before, .new-divider::after { content: ""; flex: 1; height: 1px; background: color-mix(in srgb, var(--amber) 35%, transparent); }
  .sender-face { width: 28px; flex: none; margin-right: var(--space-8); align-self: flex-start; }
  .day { display: flex; justify-content: center; padding: var(--space-16) 0 var(--space-8); }
  .notice-line { display: flex; justify-content: center; padding: var(--space-4) var(--space-16); user-select: text; }
  .notice-line span { padding: var(--space-4) var(--space-12); border-radius: var(--radius-control); background: var(--chat-theirs); font: var(--text-caption); color: var(--text-muted); text-align: center; }
  .day span { padding: var(--space-4) var(--space-12); border-radius: var(--radius-control); background: var(--chat-theirs); font: var(--text-caption); font-weight: 600; color: var(--text-strong); }

  .line { display: flex; padding-top: var(--space-2); padding-right: 70px; }
  .line.first { padding-top: var(--space-6); }
  .line.mine { justify-content: flex-end; padding-right: 0; padding-left: 70px; }
  /* A chat app's bubble (`ChatBubbleShape`): round, with a small tail at its top corner on the first message of a run
     and a square corner under it; the next message of the run meets it with a small round. Every bubble keeps the
     tail's room on its side, so a run lines up. */
  .bubble { position: relative; max-width: 560px; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-6) 10px; margin-left: 7px; background: var(--chat-theirs); border-radius: var(--radius-chat-bubble); user-select: text; }
  .bubble.mine { margin-left: 0; margin-right: 7px; background: var(--chat-mine); }
  .bubble:not(.tailed) { border-top-left-radius: var(--radius-chat-join); }
  .bubble.mine:not(.tailed) { border-top-left-radius: var(--radius-chat-bubble); border-top-right-radius: var(--radius-chat-join); }
  .bubble.joins { border-bottom-left-radius: var(--radius-chat-join); }
  .bubble.mine.joins { border-bottom-left-radius: var(--radius-chat-bubble); border-bottom-right-radius: var(--radius-chat-join); }
  .bubble.tailed { border-top-left-radius: 0; }
  .bubble.mine.tailed { border-top-left-radius: var(--radius-chat-bubble); border-top-right-radius: 0; }
  .bubble.tailed::before { content: ""; position: absolute; top: 0; left: -7px; width: 7px; height: 9px; background: inherit; clip-path: polygon(0 0, 100% 0, 100% 100%); }
  .bubble.mine.tailed::before { left: auto; right: -7px; clip-path: polygon(0 0, 100% 0, 0 100%); }
  .bubble.bare { padding: 0; background: transparent; }
  .bubble.bare::before { display: none; }
  .sender { font: var(--text-label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .deleted { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-body); font-style: italic; color: var(--chat-stamp); }
  /* The time sits after the text on its last line, as a chat app has it. */
  .body { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: flex-end; column-gap: var(--space-8); }
  .body:empty { display: none; }
  .text { flex: 1 1 auto; min-width: 0; font: var(--text-body); color: var(--paper); white-space: pre-wrap; overflow-wrap: anywhere; }
  .stamp { margin-left: auto; display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--chat-stamp); white-space: nowrap; }
  /* Quick forward + chevron menu buttons at a message's top corner under the pointer (`MessageMenuButton`). */
  .bubble-actions { position: absolute; top: var(--space-4); right: var(--space-4); display: inline-flex; align-items: center; gap: var(--space-2); border-radius: var(--radius-chip); background: inherit; opacity: 0; transition: opacity 120ms ease; }
  .bubble:hover .bubble-actions, .bubble-actions:focus-within { opacity: 1; }
  .bubble-action { width: 20px; height: 20px; padding: 0; display: grid; place-items: center; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text2); }
  .bubble-action:hover:not(:disabled) { color: var(--paper); border: 0; background: var(--row-hover); }
  .photo { padding: 0; border: 0; background: none; cursor: zoom-in; display: block; }
  .photo img { display: block; max-width: 300px; max-height: 240px; border-radius: var(--radius-card); object-fit: cover; }
  .file { display: flex; align-items: center; gap: var(--space-8); font: var(--text-detail); color: var(--text2); }
  .file-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--paper); }
  .file audio { height: 32px; min-width: 0; flex: 1; }
  .small { font: var(--text-label); padding: var(--space-2) var(--space-8); }

  .receipt-foot { flex-basis: 100%; display: flex; justify-content: flex-end; padding-top: var(--space-2); padding-right: calc(7px + var(--space-4)); }
  .receipt-link { padding: 0; border: 0; background: none; font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text3); cursor: pointer; }
  .receipt-link:hover:not(:disabled) { background: none; border: 0; color: var(--text2); text-decoration: underline; }

  .typing-row { padding-top: var(--space-8); }
  .typing-bubble { flex-direction: row; align-items: center; gap: var(--space-8); padding: var(--space-6) var(--space-12); user-select: none; }
  .typing-dots { display: inline-flex; align-items: center; gap: var(--space-4); }
  .typing-dots span { width: 5px; height: 5px; border-radius: 50%; background: var(--text3); animation: typing-pulse 1.2s ease-in-out infinite; }
  .typing-dots span:nth-child(2) { animation-delay: 0.2s; }
  .typing-dots span:nth-child(3) { animation-delay: 0.4s; }
  .typing-label { font: var(--text-caption); color: var(--text2); }
  @keyframes typing-pulse { 0%, 80%, 100% { opacity: 0.3; transform: translateY(0); } 40% { opacity: 1; transform: translateY(-2px); } }

  .info-scrim { position: fixed; inset: 0; z-index: 55; }
  .info-pop { position: fixed; width: 268px; max-height: 320px; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-8); padding: var(--space-12); box-sizing: border-box; background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); }
  .info-head { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); }
  .info-head strong { font: var(--text-emphasis); color: var(--paper); }
  .info-row { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); font: var(--text-detail); color: var(--text-strong); }
  .info-key { display: inline-flex; align-items: center; gap: var(--space-6); color: var(--text2); }
  .info-val { font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text3); white-space: nowrap; }
  .info-group { display: flex; flex-direction: column; gap: var(--space-4); padding-top: var(--space-6); border-top: 1px solid var(--separator); }
  .info-label { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-label); color: var(--text2); }
  .info-person { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); padding: var(--space-2) 0; }
  .info-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: var(--text-detail); color: var(--paper); }
  .info-empty { font: var(--text-detail); color: var(--text3); padding-top: var(--space-4); border-top: 1px solid var(--separator); }

  .foot { flex: none; display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-6) 0 var(--space-12); }
  .notice { margin: 0; padding: 0 var(--space-4); font: var(--text-detail); color: var(--text3); }
  .tray { display: flex; align-items: center; gap: var(--space-8); padding: 3px var(--space-8); }
  /* `ComposerTray`: comes out from behind the box's top, narrower than the box by a little more than its corner (the
     quote of an answer runs as wide as the box), on the composer's tray color with its line. */
  .ctray { position: relative; z-index: 0; margin: 0 var(--space-24) -22px; padding: var(--space-4) 10px 20px; background: var(--composer-tray); border: 1px solid var(--field-stroke); border-bottom: 0; border-radius: var(--radius-composer) var(--radius-composer) 0 0; }
  .ctray.full { margin-left: 0; margin-right: 0; }
  .ctray + .ctray { margin-top: 0; }
  .tray-line { font: var(--text-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tray-line.wrap { flex: 1; white-space: normal; }
  /* `ChatMarkButton`: an outlined capsule with the mark the chat gets and its word. */
  .mark { display: inline-flex; align-items: center; gap: var(--space-6); height: 26px; padding: 0 var(--space-12); border: 1px solid var(--separator); border-radius: var(--radius-control); background: transparent; color: var(--text-strong); font: var(--text-label); font-weight: 600; white-space: nowrap; }
  .mark:hover:not(:disabled) { background: var(--smoke); border-color: var(--separator); color: var(--paper); }
  .mint { display: inline-flex; color: var(--mint); }
  .amber { display: inline-flex; color: var(--amber); }
  .small-ghost { height: 26px; padding: 0 var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); font: var(--text-label); white-space: nowrap; }
  .small-ghost:hover:not(:disabled) { background: var(--row-hover); border: 0; color: var(--paper); }
  .line.reacted { flex-wrap: wrap; }
  .reactions { flex-basis: 100%; display: flex; margin-top: calc(-1 * var(--space-2)); padding-left: calc(7px + var(--space-12)); }
  .line.mine .reactions { justify-content: flex-end; padding-left: 0; padding-right: calc(7px + var(--space-12)); }
  .bubble :global(.quote) { margin-bottom: var(--space-2); }
  .files { display: flex; flex-wrap: wrap; gap: var(--space-6); }
  .chip { display: inline-flex; align-items: center; gap: var(--space-4); max-width: 220px; padding: var(--space-2) var(--space-4) var(--space-2) var(--space-8); border-radius: var(--radius-chip); background: var(--smoke); font: var(--text-label); color: var(--text-strong); }
  .chip-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chip-x { width: 18px; height: 18px; padding: 0; display: grid; place-items: center; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text3); }
  .tags { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-4); border: 1px solid var(--field-stroke); border-radius: var(--radius-sheet); background: var(--composer-tray); }
  .tag { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-4) var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; text-align: left; font: var(--text-control); color: var(--paper); }
  .tag:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .nook-mark { width: 22px; height: 22px; flex: none; display: grid; place-items: center; border-radius: 50%; color: var(--iris); background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .tag-words { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .tag-detail { font: var(--text-caption); color: var(--text3); }
  .emoji-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(32px, 1fr)); gap: var(--space-2); max-height: 160px; overflow-y: auto; padding: var(--space-6); border: 1px solid var(--field-stroke); border-radius: var(--radius-sheet); background: var(--composer-tray); }
  .emoji { height: 32px; padding: 0; border: 0; border-radius: var(--radius-control); background: transparent; font: var(--text-heading); font-weight: 400; }
  .emoji:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .leading { display: flex; align-items: center; gap: var(--space-2); align-self: flex-end; min-height: 32px; }
  .hidden { display: none; }
  .box.dragging { border-color: var(--iris); }
  .call { display: flex; align-items: center; gap: var(--space-8); }
  .call-mark { width: 34px; height: 34px; flex: none; display: grid; place-items: center; border-radius: 50%; color: var(--mint); background: color-mix(in srgb, var(--mint) 16%, transparent); }
  .call-mark.quiet { color: var(--text2); background: color-mix(in srgb, var(--text2) 16%, transparent); }
  .call-mark.missed { color: var(--coral); background: color-mix(in srgb, var(--coral) 16%, transparent); }
  .call-words { display: flex; flex-direction: column; gap: var(--space-2); }
  .call-title { font: var(--text-emphasis); line-height: 1.3; color: var(--paper); white-space: nowrap; }
  .call-title.missed { color: var(--coral); }
  .call-detail { font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text3); white-space: nowrap; }
  .edited { display: inline-flex; align-items: center; gap: var(--space-2); padding: 0; border: 0; background: none; font: inherit; color: inherit; cursor: pointer; }
  .edited:hover:not(:disabled) { background: none; border: 0; text-decoration: underline; }
  .recording { flex: 1; align-self: center; display: inline-flex; align-items: center; gap: var(--space-8); font: var(--text-label); font-variant-numeric: tabular-nums; color: var(--paper); }
  .rec-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--coral); animation: blink 1s ease-in-out infinite; }
  @keyframes blink { 50% { opacity: 0.35; } }
  @media (prefers-reduced-motion: reduce) { .rec-dot, .typing-dots span { animation: none; } }
  /* The answer field (`ChatReplyField`): the composer's box with the round send button inside it. */
  .box { position: relative; z-index: 1; display: flex; align-items: flex-end; gap: var(--space-8); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); background: var(--composer-tray); border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); transition: background 120ms ease, border-color 120ms ease; }
  .box:focus-within { background: var(--composer); border-color: var(--separator); }
  textarea { flex: 1; min-width: 0; min-height: 32px; max-height: 160px; field-sizing: content; resize: none; padding: var(--space-6) 0; border: 0 !important; background: transparent; box-shadow: none !important; font: var(--text-body); color: var(--paper); }
  textarea::placeholder { color: var(--text3); }
  .send { flex: none; width: 32px; height: 32px; padding: 0; display: grid; place-items: center; border: 0; border-radius: 50%; background: var(--smoke); color: var(--text3); }
  .send.ready { background: var(--iris); color: var(--on-iris); }
  .send:disabled { opacity: 1; cursor: default; }
  .send.ready:hover:not(:disabled) { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }
</style>
