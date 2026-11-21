<script lang="ts">
  // Asking Nook about words selected anywhere in this window (`SelectionAsk` on the Mac): a small bar above the
  // selection (Ask Nook, Explain, Translate, Quote in an agent session, Copy) and, after a click, the answer in a card
  // beside it. Mounted once per window. It costs nothing at rest: it only listens to the selection changing and the
  // pointer going up, and reads the selection once when one was just made. The card's question goes through the same
  // `ask` command as the chat.
  import { onMount } from "svelte";
  import type { UnlistenFn } from "@tauri-apps/api/event";
  import { api, events } from "../lib/api";
  import { tr } from "../lib/i18n.svelte";
  import {
    appendQuote,
    chatContextFromRows,
    isDeliberate,
    message,
    origin,
    wanted,
    type Rect,
    type SelectionMode,
  } from "../lib/selection-ask";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import type { Conversation } from "../lib/types";
  import Ico from "./ui/Ico.svelte";
  import MessageView from "./MessageView.svelte";

  const CARD_WIDTH = 400;

  let stage = $state<"hidden" | "bar" | "card">("hidden");
  let selection = $state("");
  let anchor = $state<Rect>({ left: 0, top: 0, width: 0, height: 0 });
  let viewport = $state({ width: 0, height: 0 });
  let width = $state(0);
  let height = $state(0);
  let conversationId = $state<string | null>(null);
  let conversation = $state<Conversation | null>(null);
  let draft = $state("");
  /// The messages a selection starts and ends in (`data-message-id`), plus its Chats detail container when inside the
  /// Chats tab, so the surrounding conversation goes with the question as hidden context.
  let within: { first: string; last: string; chatRoot: Element | null } | null = null;
  /// When the selection is inside an agent session panel, its reply textarea receives "Quote".
  let quoteTarget = $state<HTMLTextAreaElement | null>(null);
  let root = $state<HTMLDivElement | null>(null);
  let answerEl = $state<HTMLDivElement | null>(null);
  let field = $state<HTMLInputElement | null>(null);

  const enabled = $derived(nook.settings?.selectionAsk !== false);
  const busy = $derived(
    !!conversationId && (nook.nooks.find((n) => n.id === conversationId)?.status === "working" || !!conversation?.messages.some((m) => m.streaming)),
  );
  // What came after the question the bar asked (that one shows as the quote on top).
  const messages = $derived(conversation?.messages.slice(1) ?? []);
  const lastId = $derived(messages[messages.length - 1]?.id);
  const lastStream = $derived(lastId ? nook.streaming[lastId] ?? "" : "");
  const place = $derived(
    origin(
      { width: width || (stage === "card" ? CARD_WIDTH : 320), height: height || 36 },
      anchor,
      { left: 0, top: 0, width: viewport.width, height: viewport.height },
      stage === "card",
      6,
    ),
  );

  // Follow the growing answer as tokens stream in (`.defaultScrollAnchor(.bottom, for: .sizeChanges)` on the Mac).
  $effect(() => {
    void messages.length;
    void lastStream;
    if (stage === "card" && answerEl) {
      answerEl.scrollTop = answerEl.scrollHeight;
    }
  });

  const modes: { mode: SelectionMode; icon: string }[] = [
    { mode: "answer", icon: "sparkles" },
    { mode: "explain", icon: "lightbulb" },
    { mode: "translate", icon: "languages" },
  ];

  function title(mode: SelectionMode): string {
    switch (mode) {
      case "answer": return tr("Vraag Nook", "Ask Nook");
      case "explain": return tr("Leg uit", "Explain");
      case "translate": return tr("Vertaal", "Translate");
    }
  }

  /// The request under the quoted selection, in the interface language, so it reads well in the chat afterwards.
  function instruction(mode: SelectionMode): string {
    switch (mode) {
      case "answer": return tr("Beantwoord dit. Is het geen vraag, vertel me dan wat ervan belangrijk is.", "Answer this. If it is not a question, tell me what matters about it.");
      case "explain": return tr("Leg dit uit in gewone woorden.", "Explain this in plain words.");
      case "translate": return tr("Vertaal dit naar het Nederlands.", "Translate this into English.");
    }
  }

  // MARK: Watching the selection

  let press: { x: number; y: number } | null = null;
  let pointerDown = false;
  let timer: ReturnType<typeof setTimeout> | null = null;

  function schedule(delay: number) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => ((timer = null), look()), delay);
  }

  function elementOf(node: Node | null): Element | null {
    if (!node) return null;
    return node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
  }

  /// Finds the agent session's reply textarea when the selection sits inside a session panel (outside its composer).
  function findQuoteTarget(start: Element | null, end: Element | null): HTMLTextAreaElement | null {
    if (!start || !end) return null;
    if (start.closest(".composer") || end.closest(".composer")) return null;
    const panel = start.closest(".panel");
    if (!panel || panel !== end.closest(".panel")) return null;
    const area = panel.querySelector<HTMLTextAreaElement>(".composer textarea");
    return area && !area.disabled ? area : null;
  }

  function look() {
    const s = document.getSelection();
    const text = s && s.rangeCount ? s.toString() : "";
    const startEl = s ? elementOf(s.anchorNode) : null;
    const endEl = s ? elementOf(s.focusNode) : null;
    const target = findQuoteTarget(startEl, endEl);
    // In an agent session, Quote is offered even when Selection Ask is turned off (`quoteOnly` on the Mac).
    const found = wanted(enabled || !!target, s && s.rangeCount ? { text, collapsed: s.isCollapsed, start: startEl, end: endEl } : null);
    if (!found || !s) {
      if (stage === "bar") hide();
      return;
    }
    if (stage === "bar" && found === selection && target === quoteTarget) return;
    const range = s.getRangeAt(0);
    // The line the selection ends on is where the eye is; a selection over several lines uses its whole box.
    const box = range.getBoundingClientRect();
    if (!box.width && !box.height) return;
    // The card is open about something else: a new selection outside it asks about the new words instead.
    if (stage === "card") closeCard();
    selection = found;
    quoteTarget = target;
    const messageElOf = (el: Element | null) => el?.closest("[data-message-id]") ?? null;
    const firstEl = messageElOf(startEl), lastEl = messageElOf(endEl);
    const first = firstEl?.getAttribute("data-message-id") ?? null;
    const last = lastEl?.getAttribute("data-message-id") ?? null;
    const chatRoot = firstEl?.hasAttribute("data-chat-key") || lastEl?.hasAttribute("data-chat-key")
      ? (firstEl ?? lastEl)?.closest(".detail") ?? null
      : null;
    within = first && last
      ? { first, last, chatRoot }
      : first || last
        ? { first: (first ?? last)!, last: (last ?? first)!, chatRoot }
        : null;
    anchor = { left: box.left, top: box.top, width: box.width, height: box.height };
    viewport = { width: window.innerWidth, height: window.innerHeight };
    width = 0;
    height = 0;
    stage = "bar";
  }

  function inside(target: EventTarget | null): boolean {
    return !!root && target instanceof Node && root.contains(target);
  }

  function pointerdown(e: PointerEvent) {
    if (inside(e.target)) return;
    pointerDown = e.button === 0;
    press = pointerDown ? { x: e.clientX, y: e.clientY } : null;
    // A click starts a new selection or clears this one; the card stays until you close it.
    if (stage === "bar") hide();
  }

  function pointerup(e: PointerEvent) {
    if (!pointerDown) return;
    pointerDown = false;
    const from = press;
    press = null;
    if (inside(e.target) || !from) return;
    // A double click selects its word as the button goes up: let the page settle first.
    if (isDeliberate(from, { x: e.clientX, y: e.clientY }, e.detail)) schedule(60);
  }

  function selectionchange() {
    // While the button is down the pointer-up decides; otherwise the selection was made with the keys.
    if (pointerDown || stage === "card") return;
    schedule(stage === "bar" ? 60 : 250);
  }

  function keydown(e: KeyboardEvent) {
    if (stage === "hidden") return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      dismiss();
      return;
    }
    // Typing goes on under the bar: the bar is out of the way. A shortcut (Ctrl+C) leaves it.
    if (stage === "bar" && !inside(e.target) && !e.ctrlKey && !e.metaKey && !e.shiftKey && e.key.length === 1) hide();
  }

  function scrolled(e: Event) {
    if (stage === "bar" && !inside(e.target)) hide();
  }

  onMount(() => {
    const opts = { capture: true } as const;
    document.addEventListener("selectionchange", selectionchange);
    window.addEventListener("pointerdown", pointerdown, opts);
    window.addEventListener("pointerup", pointerup, opts);
    window.addEventListener("keydown", keydown, opts);
    window.addEventListener("scroll", scrolled, { capture: true, passive: true });
    window.addEventListener("resize", hide);
    window.addEventListener("blur", hide);
    return () => {
      if (timer) clearTimeout(timer);
      document.removeEventListener("selectionchange", selectionchange);
      window.removeEventListener("pointerdown", pointerdown, opts);
      window.removeEventListener("pointerup", pointerup, opts);
      window.removeEventListener("keydown", keydown, opts);
      window.removeEventListener("scroll", scrolled, { capture: true });
      window.removeEventListener("resize", hide);
      window.removeEventListener("blur", hide);
      stopListening();
    };
  });

  // MARK: The card

  let unlisten: Promise<UnlistenFn>[] = [];

  function startListening(id: string) {
    stopListening();
    unlisten = [
      events.onStream((e) => {
        if (e.nookId === id) nook.streaming[e.messageId] = e.text;
      }),
      events.onNookUpdated((updated) => {
        if (updated === id) reload(id);
      }),
    ];
  }

  function stopListening() {
    for (const un of unlisten) un.then((f) => f()).catch(() => {});
    unlisten = [];
  }

  async function reload(id: string) {
    const conv = await api.nook(id).catch(() => null);
    if (conversationId !== id) return;
    conversation = conv;
    for (const m of conv?.messages ?? []) if (!m.streaming) delete nook.streaming[m.id];
  }

  /// Ask Nook, Explain or Translate in the bar: the bar becomes the card, with Nook's answer coming in.
  async function ask(mode: SelectionMode) {
    const text = selection;
    const note = context();
    try {
      // A conversation of its own, in the background: the chat on screen stays as it is.
      const id = await api.newNookInBackground();
      conversationId = id;
      conversation = null;
      startListening(id);
      document.getSelection()?.removeAllRanges();
      width = 0;
      height = 0;
      stage = "card";
      await api.askAboutSelection(id, message(text, instruction(mode)), note);
      await reload(id);
      field?.focus();
    } catch (e) {
      toast.error(String(e));
      dismiss();
    }
  }

  /// The messages around a selection in the conversation on screen (Nook Chat or Chats tab), as the hidden note's
  /// context; null elsewhere.
  function context(): string | null {
    if (!within) return null;
    const you = tr("Jij", "You");
    if (within.chatRoot) {
      const contact = within.chatRoot.querySelector(".head .name")?.textContent?.trim() ?? "";
      const rows = Array.from(within.chatRoot.querySelectorAll<HTMLElement>(".line[data-chat-key][data-message-id]")).map((row) => ({
        id: row.getAttribute("data-message-id") ?? "",
        speaker: row.classList.contains("mine") ? you : (row.getAttribute("data-sender") || contact),
        text: row.querySelector(".body .text")?.textContent ?? "",
      }));
      return chatContextFromRows(rows, within.first, within.last, contact, you);
    }
    const rows = (nook.active?.messages ?? []).map((m) => ({
      id: m.id,
      speaker: m.fromUser ? you : "Nook",
      text: m.text,
    }));
    return chatContextFromRows(rows, within.first, within.last, "Nook", you);
  }

  /// Quotes the selection into the current agent session's reply box (`ComposerQuotes` on the Mac).
  function quote() {
    const text = selection;
    const target = quoteTarget;
    hide();
    if (!target) return;
    document.getSelection()?.removeAllRanges();
    const next = appendQuote(target.value, text);
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")?.set;
    if (setter) setter.call(target, next);
    else target.value = next;
    target.dispatchEvent(new Event("input", { bubbles: true }));
    target.focus();
    target.setSelectionRange(next.length, next.length);
  }

  async function copy() {
    const text = selection;
    hide();
    try {
      await navigator.clipboard.writeText(text);
      toast.success(tr("Gekopieerd", "Copied"));
    } catch { /* The clipboard can be busy. */ }
  }

  async function sendFollowUp() {
    const id = conversationId;
    const text = draft.trim();
    if (!id || !text || busy) return;
    draft = "";
    try {
      await api.askAboutSelection(id, text);
      await reload(id);
    } catch (e) {
      toast.error(String(e));
    }
  }

  function continueInChat() {
    const id = conversationId;
    dismiss();
    if (id) api.showMain(`nook:${id}`).catch(() => {});
  }

  function stop() {
    if (conversationId) api.stop(conversationId).catch(() => {});
  }

  function closeCard() {
    stopListening();
    conversationId = null;
    conversation = null;
    draft = "";
  }

  function hide() {
    if (stage === "bar") {
      stage = "hidden";
      quoteTarget = null;
    }
  }

  function dismiss() {
    closeCard();
    quoteTarget = null;
    stage = "hidden";
  }
</script>

{#if stage !== "hidden"}
  <div
    class="selection-ask"
    class:card={stage === "card"}
    bind:this={root}
    bind:offsetWidth={width}
    bind:offsetHeight={height}
    style:left="{place.x}px"
    style:top="{place.y}px"
    role={stage === "bar" ? "toolbar" : "dialog"}
    aria-label={tr("Vraag Nook over de selectie", "Ask Nook about the selection")}
  >
    {#if stage === "bar"}
      {#if enabled}
        {#each modes as m, i (m.mode)}
          <button class="bar-button" class:accent={m.mode === "answer"} title={title(m.mode)} onmousedown={(e) => e.preventDefault()} onclick={() => ask(m.mode)}>
            <Ico name={m.icon} size={13} /><span>{title(m.mode)}</span>
          </button>
          {#if i === 0}<span class="divider"></span>{/if}
        {/each}
      {/if}
      {#if quoteTarget}
        {#if enabled}<span class="divider"></span>{/if}
        <button class="bar-button" title={tr("Citeer", "Quote")} onmousedown={(e) => e.preventDefault()} onclick={quote}>
          <Ico name="text-quote" size={13} /><span>{tr("Citeer", "Quote")}</span>
        </button>
      {/if}
      {#if enabled || quoteTarget}<span class="divider"></span>{/if}
      <button class="bar-button" title={tr("Kopieer", "Copy")} onmousedown={(e) => e.preventDefault()} onclick={copy}>
        <Ico name="copy" size={13} /><span>{tr("Kopieer", "Copy")}</span>
      </button>
    {:else}
      <header>
        <span class="mark" aria-hidden="true"><Ico name="text-quote" size={13} /></span>
        <p class="quote">{selection}</p>
        <div class="tools">
          <button class="tool" title={tr("Verder in de chat", "Continue in chat")} aria-label={tr("Verder in de chat", "Continue in chat")} onclick={continueInChat}><Ico name="square-arrow-out-up-right" size={14} /></button>
          <button class="tool" title={tr("Sluiten", "Close")} aria-label={tr("Sluiten", "Close")} onclick={dismiss}><Ico name="x" size={14} /></button>
        </div>
      </header>
      <div class="answer" bind:this={answerEl}>
        {#if conversation && messages.length > 0}
          {#each messages as m (m.id)}
            <MessageView message={m} nookId={conversation.id} last={m.id === lastId} />
          {/each}
        {:else}
          <div class="thinking">
            <span class="spin" aria-hidden="true"></span>
            <span>{tr("Even nadenken…", "Thinking…")}</span>
          </div>
        {/if}
      </div>
      <form class="follow-up" onsubmit={(e) => (e.preventDefault(), sendFollowUp())}>
        <div class="follow-box">
          <input bind:this={field} bind:value={draft} placeholder={tr("Stel een vervolgvraag…", "Ask a follow-up…")} />
          {#if busy}
            <button type="button" class="send stop" title={tr("Stop", "Stop")} aria-label={tr("Stop", "Stop")} onclick={stop}><Ico name="square" size={9} fill="currentColor" stroke={0} /></button>
          {:else}
            <button type="submit" class="send" title={tr("Verstuur", "Send")} aria-label={tr("Verstuur", "Send")} disabled={!draft.trim()}><Ico name="arrow-up" size={14} stroke={2.2} /></button>
          {/if}
        </div>
      </form>
    {/if}
  </div>
{/if}

<style>
  .selection-ask {
    position: fixed;
    z-index: 1000;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-4);
    background: var(--surface);
    border: 1px solid var(--line2);
    border-radius: var(--radius-panel);
    box-shadow: var(--shadow-popover);
    user-select: none;
    animation: sel-pop var(--motion-quick) var(--ease-out);
  }
  @keyframes sel-pop {
    from { opacity: 0; transform: translateY(3px) scale(0.985); }
    to { opacity: 1; transform: translateY(0) scale(1); }
  }
  @media (prefers-reduced-motion: reduce) {
    .selection-ask { animation: none; }
  }
  .bar-button {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 26px;
    margin: 0;
    padding: 0 calc(var(--space-8) + var(--space-2));
    border: none;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text-strong);
    font: var(--text-label);
    white-space: nowrap;
    cursor: pointer;
  }
  .bar-button :global(svg) {
    color: var(--text2);
  }
  .bar-button.accent {
    color: var(--paper);
  }
  .bar-button.accent :global(svg) {
    color: var(--iris);
  }
  .bar-button:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .bar-button:hover:not(.accent) :global(svg) {
    color: var(--paper);
  }
  .divider {
    width: 1px;
    height: 16px;
    background: var(--line2);
    margin: 0 var(--space-2);
  }
  .card {
    flex-direction: column;
    align-items: stretch;
    gap: 0;
    padding: 0;
    width: 400px;
    max-width: calc(100vw - 16px);
    overflow: hidden;
    user-select: text;
  }
  header {
    display: flex;
    align-items: flex-start;
    gap: var(--space-8);
    padding: calc(var(--space-8) + var(--space-2)) var(--space-12);
    border-bottom: 1px solid var(--border);
  }
  .mark {
    display: inline-flex;
    flex: none;
    color: var(--iris);
    padding-top: var(--space-2);
  }
  .quote {
    flex: 1;
    min-width: 0;
    margin: 0;
    font: var(--text-detail);
    color: var(--text2);
    display: -webkit-box;
    -webkit-line-clamp: 3;
    line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
    white-space: pre-wrap;
  }
  .tools {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex: none;
  }
  .tool {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    margin: 0;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
  }
  .tool:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .answer {
    max-height: 380px;
    min-height: 64px;
    overflow-y: auto;
    padding: var(--space-12);
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }
  .thinking {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-detail);
    color: var(--text3);
  }
  .spin {
    width: 12px;
    height: 12px;
    flex: none;
    border: 1.5px solid var(--line2);
    border-top-color: var(--text2);
    border-radius: var(--radius-pill);
    animation: sel-spin 0.8s linear infinite;
  }
  @keyframes sel-spin {
    to { transform: rotate(360deg); }
  }
  .follow-up {
    padding: var(--space-8);
    border-top: 1px solid var(--border);
  }
  .follow-box {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-4) var(--space-4) var(--space-4) var(--space-12);
    background: var(--composer);
    border: 1px solid var(--field-stroke);
    border-radius: var(--radius-card);
  }
  .follow-box:focus-within {
    border-color: var(--iris);
  }
  .follow-box input {
    flex: 1;
    min-width: 0;
    height: 26px;
    padding: 0;
    margin: 0;
    border: 0;
    background: transparent;
    color: var(--paper);
    font: var(--text-body);
    outline: none;
  }
  .follow-box input::placeholder {
    color: var(--text3);
  }
  .send {
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    flex: none;
    margin: 0;
    padding: 0;
    border: 0;
    border-radius: var(--radius-pill);
    background: var(--iris);
    color: var(--on-iris);
    cursor: pointer;
  }
  .send:disabled {
    background: var(--smoke);
    color: var(--text3);
    cursor: default;
  }
  .send.stop {
    background: var(--paper);
    color: var(--canvas);
  }
</style>
