<script lang="ts">
  // One session as the iPhone app opens it: the whole conversation (with a computer that lists `timeline`), what waits
  // on you docked right above the composer, and a field to send the next message. While it works the composer offers
  // Steer now or After this turn (remembered). The title opens what you can do with the session: stop, snooze, rename,
  // archive. A computer that lists none of this shows the latest reply, approve, answer, send and stop, as before.
  import {
    actionLabel, attentionColor, attentionWord, canStop, companion, has, may, sendNotice, sessionActions, Feature,
    type ClientView, type DigestItem, type TimelineEntry,
  } from "../../lib/companion";
  import { renderMarkdown } from "../../lib/markdown";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";
  import ConversationScroll from "./ConversationScroll.svelte";
  import TimelineView from "./TimelineView.svelte";

  let { view, id, onback, act, took }: {
    view: ClientView;
    id: string;
    onback: () => void;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    took: (v: ClientView) => void;
  } = $props();

  const session = $derived(view.sessions.find((s) => s.id === id) ?? null);
  const live = $derived(has(view, Feature.timeline));
  const canOperate = $derived(may(view, "operate") && session?.canSend !== false);
  const canApprove = $derived(may(view, "approve"));
  const steerable = $derived(has(view, Feature.steer) && session?.canSteer === true);
  const actions = $derived(session && has(view, Feature.manage) && may(view, "operate") ? sessionActions(session) : []);

  let entries = $state<TimelineEntry[]>([]);
  let loaded = $state(false);
  let message = $state("");
  let answers = $state<Record<string, string>>({});
  let reasons = $state<Record<string, string>>({});
  let menu = $state(false);
  let confirmStop = $state(false);
  let renaming = $state<string | null>(null);
  let sending = $state(false);
  let steer = $state(readSteer());

  function readSteer(): boolean {
    try { return localStorage.getItem("companion.steer") !== "0"; } catch { return true; }
  }
  function setSteer(on: boolean) {
    steer = on;
    try { localStorage.setItem("companion.steer", on ? "1" : "0"); } catch { /* remembered for this visit only */ }
  }

  // The conversation, asked every few seconds while it is on screen (the Mac's live updates need a kept connection,
  // which this app does not hold yet).
  async function loadTimeline() {
    if (!live || document.visibilityState !== "visible") return;
    const r = await companion.call({ op: "timeline", session: id });
    if (r.response?.timeline) entries = r.response.timeline;
    loaded = true;
  }
  $effect(() => {
    if (!live) return;
    void id;
    loadTimeline();
    const timer = setInterval(loadTimeline, 3000);
    return () => clearInterval(timer);
  });

  async function send() {
    if (!session) return;
    const text = message.trim();
    if (!text || sending) return;
    sending = true;
    const steering = steerable && steer;
    const r = await companion.call({ op: "send", session: session.id, text, steer: steering || undefined, turn: steering ? session.turn : undefined });
    sending = false;
    took(r.view);
    // A message the computer refused stays in the field, to edit and send again.
    if (r.response) {
      message = "";
      const notice = sendNotice(r.response.message);
      if (notice) took({ ...r.view, notice });
      loadTimeline();
    }
  }

  function answer(item: DigestItem, text: string) {
    if (!session || !text.trim()) return;
    answers[item.id] = "";
    act(() => companion.answer(session.id, item.id, text.trim()));
  }

  function deny(item: DigestItem) {
    if (!session) return;
    const reason = (reasons[item.id] ?? "").trim();
    reasons[item.id] = "";
    act(() => (reason ? companion.deny(session.id, item.id, reason) : companion.decide(session.id, item.id, false)));
  }

  async function stop() {
    if (!session) return;
    confirmStop = false;
    menu = false;
    const r = await companion.call({ op: "stop", session: session.id, turn: session.turn });
    took(r.response?.message === "stale" ? { ...r.view, notice: sendNotice("stale") } : r.view);
  }

  async function manage(action: string, text?: string) {
    if (!session) return;
    menu = false;
    if (action === "rename" && text === undefined) {
      renaming = session.title;
      return;
    }
    const r = await companion.call({ op: "manage", session: session.id, item: action, text });
    took(r.view);
    if (r.response && action === "archive") onback();
  }
</script>

<div class="detail">
  <header>
    <button class="ghost back" onclick={onback} aria-label={tr("Terug", "Back")}><Icon name="back" size={20} /></button>
    <button class="ghost title" onclick={() => (menu = !menu)} aria-expanded={menu} disabled={!session}>
      <span class="name">{#if session}<span class="faint">{session.folder} /</span> {session.title}{:else}{tr("Sessie", "Session")}{/if}</span>
      {#if session}
        <span class="sub faint"><span class="dot" style="background:{attentionColor(session.attention)}"></span>{attentionWord(session.attention)} · {session.agent}{session.branch ? ` · ${session.branch}` : ""}</span>
      {/if}
    </button>
  </header>

  {#if menu && session}
    <div class="menu">
      {#each actions as action (action)}
        <button onclick={() => manage(action)}>{actionLabel(action)}</button>
      {/each}
      {#if canOperate && canStop(session.attention)}
        {#if confirmStop}
          <div class="row">
            <button onclick={() => (confirmStop = false)}>{tr("Annuleer", "Cancel")}</button>
            <button class="danger" onclick={stop}>{tr("Stop de sessie", "Stop the session")}</button>
          </div>
        {:else}
          <button class="danger" onclick={() => (confirmStop = true)}>{tr("Stop", "Stop")}</button>
        {/if}
      {/if}
      {#if !actions.length && !(canOperate && canStop(session.attention))}
        <p class="faint small">{tr("Hier valt vanaf de telefoon niets te beheren.", "Nothing to manage here from the phone.")}</p>
      {/if}
    </div>
  {/if}

  {#if renaming !== null && session}
    <div class="menu">
      <input bind:value={renaming} maxlength="120" aria-label={tr("Nieuwe naam", "New name")} />
      <div class="row">
        <button onclick={() => (renaming = null)}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={!renaming.trim()} onclick={() => { const name = renaming?.trim() ?? ""; renaming = null; manage("rename", name); }}>{tr("Bewaar", "Save")}</button>
      </div>
    </div>
  {/if}

  {#if !session}
    <p class="faint pad">{tr("Deze sessie is er niet meer.", "This session no longer exists.")}</p>
  {:else}
    <ConversationScroll version={[entries.length, entries[entries.length - 1]?.text.length, session.excerpt]}>
      {#if live}
        {#if !loaded}<p class="faint">{tr("Gesprek laden…", "Loading the conversation…")}</p>{/if}
        <TimelineView {entries} />
        {#if loaded && !entries.length}<p class="faint">{tr("Nog geen berichten.", "No messages yet.")}</p>{/if}
      {:else if session.excerpt}
        <h3>{tr("Laatste antwoord", "Latest reply")}</h3>
        <div class="markdown reply">{@html renderMarkdown(session.excerpt)}</div>
      {/if}
      {#if session.attention === "working"}<p class="working faint">● {tr("Aan het werk…", "Working…")}</p>{/if}
    </ConversationScroll>

    <div class="dock">
      {#each session.items as item (item.id)}
        <section class="item">
          <h3>{item.kind === "approval" ? tr("Toestemming", "Permission") : tr("Vraag", "Question")}</h3>
          <p class="ask">{item.title}</p>
          {#if item.detail}<p class="faint small">{item.detail}</p>{/if}
          {#if !canApprove}
            <p class="warn small">{tr("Deze telefoon mag dit niet beslissen; doe het op je computer.", "This phone may not decide this; do it on your computer.")}</p>
          {:else if item.kind === "approval"}
            <input class="reason" placeholder={tr("Waarom niet? (optioneel, bij weigeren)", "Why not? (optional, when denying)")} bind:value={reasons[item.id]} />
            <div class="row">
              <button class="danger" onclick={() => deny(item)}>{reasons[item.id]?.trim() ? tr("Weiger met reden", "Deny with reason") : tr("Weiger", "Deny")}</button>
              {#if item.canAllow}
                <button class="primary" onclick={() => act(() => companion.decide(session.id, item.id, true))}>{tr("Sta toe", "Allow")}</button>
              {/if}
            </div>
            {#if !item.canAllow}<p class="warn small">{tr("Dit is riskant of onbekend: toestaan kan alleen op je computer.", "This is risky or unknown: you can only allow it on your computer.")}</p>{/if}
          {:else if item.canAllow}
            <div class="options">
              {#each item.options as option, i (option)}
                <button onclick={() => answer(item, option)}>
                  <span>{option}</span>
                  {#if item.optionPreviews?.[i]}<pre>{item.optionPreviews[i]}</pre>{/if}
                </button>
              {/each}
            </div>
            <div class="row">
              <input placeholder={tr("Eigen antwoord", "Your own answer")} bind:value={answers[item.id]} onkeydown={(e) => e.key === "Enter" && answer(item, answers[item.id] ?? "")} />
              <button disabled={!answers[item.id]?.trim()} onclick={() => answer(item, answers[item.id] ?? "")}>{tr("Stuur", "Send")}</button>
            </div>
          {:else}
            <p class="warn small">{tr("Meerdere vragen tegelijk: beantwoord ze op je computer.", "Several questions at once: answer them on your computer.")}</p>
          {/if}
        </section>
      {/each}

      {#if canOperate}
        <div class="composer">
          {#if steerable}
            <div class="steer" role="radiogroup" aria-label={tr("Wanneer", "When")}>
              <button role="radio" aria-checked={steer} class:on={steer} onclick={() => setSteer(true)}>{tr("Nu bijsturen", "Steer now")}</button>
              <button role="radio" aria-checked={!steer} class:on={!steer} onclick={() => setSteer(false)}>{tr("Na deze beurt", "After this turn")}</button>
            </div>
          {/if}
          <div class="field">
            <textarea rows="1" placeholder={tr("Bericht aan de agent", "Message to the agent")} bind:value={message}></textarea>
            <button class="primary send" disabled={!message.trim() || sending} onclick={send} aria-label={tr("Verstuur", "Send")}><Icon name="arrow" size={18} /></button>
          </div>
        </div>
      {:else if session.canSend === false}
        <p class="faint small foot">{tr("Deze agent draait in een terminal op je computer: antwoord hem daar.", "This agent runs in a terminal on your computer: answer it there.")}</p>
      {/if}
    </div>
  {/if}
</div>

<style>
  .detail { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: var(--space-4); padding: var(--space-4) var(--space-8) var(--space-4) var(--space-4); border-bottom: 1px solid var(--line); }
  .back { min-width: 44px; min-height: 44px; }
  .title { flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-2); text-align: left; padding: var(--space-4) var(--space-8); min-height: 44px; }
  .name { font: var(--text-title); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
  .sub { font: var(--text-detail); display: flex; align-items: center; gap: var(--space-6); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
  .dot { width: 7px; height: 7px; border-radius: 50%; flex: none; }
  .menu { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8) var(--space-12); border-bottom: 1px solid var(--line); }
  .menu button { min-height: 44px; text-align: left; }
  .row { display: flex; gap: var(--space-8); }
  .row > * { flex: 1; min-height: 44px; min-width: 0; }
  .reply { font: var(--text-body); overflow-wrap: anywhere; }
  .working { font: var(--text-detail); margin: 0; animation: breathe 2s ease-in-out infinite; }
  @keyframes breathe { 50% { opacity: 0.45; } }
  .dock { border-top: 1px solid var(--line); padding: var(--space-8) var(--space-12) var(--space-12); display: flex; flex-direction: column; gap: var(--space-8); max-height: 60%; overflow-y: auto; }
  .item { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8) var(--space-12); border-radius: var(--radius-card); background: var(--surface); border: 1px solid var(--amber); }
  h3 { margin: 0; font: var(--text-label); color: var(--text2); text-transform: uppercase; letter-spacing: 0.04em; }
  .ask { margin: 0; font: var(--text-body); user-select: text; overflow-wrap: anywhere; }
  p { margin: 0; }
  .small { font: var(--text-detail); }
  .warn { color: var(--amber); }
  .reason { min-height: 40px; }
  .options { display: flex; flex-direction: column; gap: var(--space-6); }
  .options button { min-height: 44px; text-align: left; display: flex; flex-direction: column; align-items: stretch; gap: var(--space-4); }
  .options pre { margin: 0; font: var(--text-code); white-space: pre; overflow-x: auto; color: var(--text2); }
  .composer { display: flex; flex-direction: column; gap: var(--space-6); }
  .steer { display: flex; gap: var(--space-4); }
  .steer button { flex: 1; min-height: 34px; border-radius: var(--radius-pill); font: var(--text-label); background: transparent; color: var(--text2); }
  .steer button.on { background: var(--smoke); color: var(--paper); }
  .field { display: flex; gap: var(--space-8); align-items: flex-end; background: var(--composer); border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); }
  .field textarea { flex: 1; resize: none; min-height: 36px; max-height: 160px; border: none; background: transparent; padding: var(--space-8) 0; field-sizing: content; }
  .send { width: 40px; height: 40px; border-radius: 50%; padding: 0; display: flex; align-items: center; justify-content: center; flex: none; }
  .foot { text-align: center; padding: var(--space-4); }
  .pad { padding: var(--space-16); }
</style>
