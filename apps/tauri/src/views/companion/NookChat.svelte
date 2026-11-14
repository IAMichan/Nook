<script lang="ts">
  // A chat with Nook on your computer, as the iPhone's Nook tab opens one: ask in a new chat or continue one, and the
  // answer comes in as it is written. It runs through the computer's own brain; a plan, a mail draft or a chart in an
  // answer is shown and approved there.
  import { onMount, untrack } from "svelte";
  import { companion, type ChatLine, type ClientView } from "../../lib/companion";
  import { renderMarkdown } from "../../lib/markdown";
  import { onBack } from "../../lib/mobile";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";

  let { view, id: initial, ask: question, onback, took }: {
    view: ClientView;
    id: string | null;
    ask?: string;
    onback: () => void;
    took: (v: ClientView) => void;
  } = $props();

  let id = $state<string | null>(untrack(() => initial));
  let lines = $state<ChatLine[]>([]);
  let text = $state("");
  let sending = $state(false);
  const busy = $derived(lines.some((l) => l.streaming));

  $effect(() => onBack(() => (onback(), true)));

  async function load() {
    if (!id || document.visibilityState !== "visible") return;
    const r = await companion.call({ op: "chat", conversation: id });
    if (r.response?.messages) lines = r.response.messages;
  }

  // While Nook writes, ask often; otherwise now and then, for an answer that came in on the computer.
  $effect(() => {
    if (!id) return;
    const every = busy ? 1200 : 6000;
    const timer = setInterval(load, every);
    return () => clearInterval(timer);
  });

  async function send(words: string) {
    const clean = words.trim();
    if (!clean || sending) return;
    sending = true;
    const r = await companion.call({ op: "ask", conversation: id ?? undefined, text: clean });
    sending = false;
    took(r.view);
    if (!r.response) return;
    text = "";
    if (r.response.created) id = r.response.created;
    if (r.response.messages) lines = r.response.messages;
    else load();
  }

  async function stop() {
    if (!id) return;
    const r = await companion.call({ op: "chatStop", conversation: id });
    took(r.view);
    if (r.response?.messages) lines = r.response.messages;
  }

  onMount(() => {
    if (initial) load();
    else if (question) send(question);
  });
</script>

<div class="nook">
  <header>
    <button class="ghost back" onclick={onback} aria-label={tr("Terug", "Back")}><Icon name="back" size={20} /></button>
    <h2>{tr("Nook op {name}", "Nook on {name}", { name: view.macName || tr("je computer", "your computer") })}</h2>
  </header>
  <ConversationScroll version={[lines.length, lines[lines.length - 1]?.text.length, lines[lines.length - 1]?.status]}>
    {#if !lines.length && !sending}<p class="faint">{tr("Vraag Nook iets.", "Ask Nook something.")}</p>{/if}
    {#each lines as l (l.id)}
      {#if !l.fromNook}
        <div class="mine">{l.text}</div>
      {:else}
        <div class="answer" class:failed={l.failed}>
          {#if l.text}<div class="markdown">{@html renderMarkdown(l.text)}</div>{:else if l.streaming}<p class="faint status">{l.status || tr("Aan het denken…", "Thinking…")}</p>{/if}
          {#if l.onMac}<p class="faint small">{tr("Er hoort iets bij dit antwoord dat je op je computer bekijkt en goedkeurt.", "Something in this answer is shown and approved on your computer.")}</p>{/if}
        </div>
      {/if}
    {/each}
  </ConversationScroll>
  <div class="composer">
    <div class="field">
      <textarea rows="1" placeholder={tr("Vraag Nook iets", "Ask Nook something")} bind:value={text} disabled={sending}></textarea>
      {#if busy}
        <button class="send" onclick={stop} aria-label={tr("Stop", "Stop")}><Icon name="stop" size={18} /></button>
      {:else}
        <button class="primary send" disabled={!text.trim() || sending} onclick={() => send(text)} aria-label={tr("Verstuur", "Send")}><Icon name="arrow" size={18} /></button>
      {/if}
    </div>
  </div>
</div>

<style>
  .nook { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: var(--space-4); padding: var(--space-4) var(--space-12) var(--space-4) var(--space-4); border-bottom: 1px solid var(--line); }
  header h2 { margin: 0; font: var(--text-title); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .back { min-width: 44px; min-height: 44px; }
  .mine { align-self: flex-end; max-width: 85%; background: var(--bubble); border-radius: var(--radius-bubble); padding: var(--space-8) var(--space-12); white-space: pre-wrap; font: var(--text-body); user-select: text; overflow-wrap: anywhere; }
  .answer { font: var(--text-body); overflow-wrap: anywhere; display: flex; flex-direction: column; gap: var(--space-4); }
  .answer.failed { color: var(--coral); }
  .status { animation: breathe 2s ease-in-out infinite; }
  @keyframes breathe { 50% { opacity: 0.45; } }
  p { margin: 0; }
  .small { font: var(--text-detail); }
  .composer { border-top: 1px solid var(--line); padding: var(--space-8) var(--space-12) var(--space-12); }
  .field { display: flex; gap: var(--space-8); align-items: flex-end; background: var(--composer); border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); }
  .field textarea { flex: 1; resize: none; min-height: 36px; max-height: 160px; border: none; background: transparent; padding: var(--space-8) 0; field-sizing: content; }
  .send { width: 40px; height: 40px; border-radius: 50%; padding: 0; display: flex; align-items: center; justify-content: center; flex: none; }
</style>
