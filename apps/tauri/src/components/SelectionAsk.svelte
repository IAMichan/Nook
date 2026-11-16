<script lang="ts">
  // Asking Nook about words selected anywhere in this window (`SelectionAsk` on the Mac): a small bar above the
  // selection (Ask Nook, Explain, Translate, Copy) and, after a click, the answer in a card beside it. Mounted once per
  // window. It costs nothing at rest: it only listens to the selection changing and the pointer going up, and reads the
  // selection once when one was just made. The card's question goes through the same `ask` command as the chat.
  import { onMount } from "svelte";
  import type { UnlistenFn } from "@tauri-apps/api/event";
  import { api, events } from "../lib/api";
  import { tr } from "../lib/i18n.svelte";
  import { isDeliberate, message, origin, wanted, type Rect, type SelectionMode } from "../lib/selection-ask";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import type { Conversation } from "../lib/types";
  import Icon from "./Icon.svelte";
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
  let root = $state<HTMLDivElement | null>(null);
  let field = $state<HTMLInputElement | null>(null);

  const enabled = $derived(nook.settings?.selectionAsk !== false);
  const busy = $derived(
    !!conversationId && (nook.nooks.find((n) => n.id === conversationId)?.status === "working" || !!conversation?.messages.some((m) => m.streaming)),
  );
  // What came after the question the bar asked (that one shows as the quote on top).
  const messages = $derived(conversation?.messages.slice(1) ?? []);
  const lastId = $derived(messages[messages.length - 1]?.id);
  const place = $derived(
    origin(
      { width: width || (stage === "card" ? CARD_WIDTH : 320), height: height || 36 },
      anchor,
      { left: 0, top: 0, width: viewport.width, height: viewport.height },
      stage === "card",
      6,
    ),
  );

  const modes: { mode: SelectionMode; icon: "sparkle" | "memory" | "globe" }[] = [
    { mode: "answer", icon: "sparkle" },
    { mode: "explain", icon: "memory" },
    { mode: "translate", icon: "globe" },
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

  function look() {
    const s = document.getSelection();
    const text = s && s.rangeCount ? s.toString() : "";
    const found = wanted(enabled, s && s.rangeCount ? { text, collapsed: s.isCollapsed, start: elementOf(s.anchorNode), end: elementOf(s.focusNode) } : null);
    if (!found || !s) {
      if (stage === "bar") hide();
      return;
    }
    if (stage === "bar" && found === selection) return;
    const range = s.getRangeAt(0);
    // The line the selection ends on is where the eye is; a selection over several lines uses its whole box.
    const box = range.getBoundingClientRect();
    if (!box.width && !box.height) return;
    // The card is open about something else: a new selection outside it asks about the new words instead.
    if (stage === "card") closeCard();
    selection = found;
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
      await api.askAboutSelection(id, message(text, instruction(mode)));
      await reload(id);
      field?.focus();
    } catch (e) {
      toast.error(String(e));
      dismiss();
    }
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
    if (stage === "bar") stage = "hidden";
  }

  function dismiss() {
    closeCard();
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
      {#each modes as m, i (m.mode)}
        <button class="bar-button" class:accent={m.mode === "answer"} title={title(m.mode)} onmousedown={(e) => e.preventDefault()} onclick={() => ask(m.mode)}>
          <Icon name={m.icon} size={13} /><span>{title(m.mode)}</span>
        </button>
        {#if i === 0}<span class="divider"></span>{/if}
      {/each}
      <span class="divider"></span>
      <button class="bar-button" title={tr("Kopieer", "Copy")} onmousedown={(e) => e.preventDefault()} onclick={copy}>
        <Icon name="copy" size={13} /><span>{tr("Kopieer", "Copy")}</span>
      </button>
    {:else}
      <header>
        <span class="mark"><Icon name="note" size={13} /></span>
        <p class="quote">{selection}</p>
        <button class="ghost icon" title={tr("Verder in de chat", "Continue in chat")} onclick={continueInChat}><Icon name="chat" size={15} /></button>
        <button class="ghost icon" title={tr("Sluiten", "Close")} onclick={dismiss}><Icon name="x" size={15} /></button>
      </header>
      <div class="answer">
        {#if conversation}
          {#each messages as m (m.id)}
            <MessageView message={m} nookId={conversation.id} last={m.id === lastId} />
          {/each}
        {:else}
          <p class="faint small">{tr("Even nadenken…", "Thinking…")}</p>
        {/if}
      </div>
      <form class="follow-up" onsubmit={(e) => (e.preventDefault(), sendFollowUp())}>
        <input bind:this={field} bind:value={draft} placeholder={tr("Stel een vervolgvraag…", "Ask a follow-up…")} />
        {#if busy}
          <button type="button" class="ghost icon" title={tr("Stop", "Stop")} onclick={stop}><Icon name="stop" size={14} /></button>
        {:else}
          <button type="submit" class="ghost icon" title={tr("Verstuur", "Send")} disabled={!draft.trim()}><Icon name="arrow" size={15} /></button>
        {/if}
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
  }
  .bar-button {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 26px;
    padding: 0 var(--space-12);
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
  .bar-button.accent :global(svg) {
    color: var(--iris);
  }
  .bar-button.accent {
    color: var(--paper);
  }
  .bar-button:hover {
    background: var(--smoke);
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
    overflow: hidden;
    user-select: text;
  }
  header {
    display: flex;
    align-items: flex-start;
    gap: var(--space-8);
    padding: var(--space-12) var(--space-16);
    border-bottom: 1px solid var(--line2);
  }
  .mark {
    color: var(--iris);
    padding-top: var(--space-2);
  }
  .quote {
    flex: 1;
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
  .answer {
    max-height: 380px;
    min-height: 64px;
    overflow-y: auto;
    padding: var(--space-16);
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
  }
  .follow-up {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-12);
    border-top: 1px solid var(--line2);
  }
  .follow-up input {
    flex: 1;
    min-width: 0;
  }
</style>
