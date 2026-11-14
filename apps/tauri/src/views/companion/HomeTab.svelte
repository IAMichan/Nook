<script lang="ts">
  // The Nook tab of the iPhone app, the computer's home: the date and a greeting, what waits on you, works and is unread
  // as tiles, For you (the sessions that wait on you and the unread chats by name, a tap away, and what Nook's home
  // lists), the agenda, what plays, the plan limits, Nook's own chats, and a box to ask Nook something.
  import { onMount, untrack } from "svelte";
  import {
    companion, greeting, has, may, needingYou, resetsIn, shortTime, unreadChats, Feature,
    type ChatDigest, type ClientView, type CompanionTab, type HomeDigest, type InboxChatDigest,
  } from "../../lib/companion";
  import { locale, tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";

  let { view, inbox, took, onsession, onchat, onnook, ontab }: {
    view: ClientView;
    inbox: InboxChatDigest[];
    took: (v: ClientView) => void;
    onsession: (id: string) => void;
    onchat: (id: string) => void;
    onnook: (id: string | null, ask?: string) => void;
    ontab: (tab: CompanionTab) => void;
  } = $props();

  let home = $state<HomeDigest | null>(null);
  let chats = $state<ChatDigest[]>([]);
  let noBrain = $state(false);
  let question = $state("");
  const now = new Date();

  const showHome = $derived(has(view, Feature.home));
  const canChat = $derived(has(view, Feature.chat) && may(view, "nookChat"));
  const canMusic = $derived(has(view, Feature.music) && may(view, "music"));
  const waiting = $derived(view.sessions.filter((s) => s.items.length > 0));
  const working = $derived(view.sessions.filter((s) => s.attention === "working").length);
  const unread = $derived(inbox.filter((c) => c.unread > 0).sort((a, b) => b.last - a.last));

  async function load() {
    if (document.visibilityState !== "visible") return;
    if (untrack(() => showHome)) {
      const r = await companion.call({ op: "home" });
      if (r.response?.home) home = r.response.home;
    }
    if (untrack(() => canChat)) {
      const r = await companion.call({ op: "chats" });
      if (r.response?.conversations) chats = r.response.conversations;
      noBrain = r.response?.message === "nobrain";
    }
  }

  onMount(() => {
    load();
    const timer = setInterval(load, 20_000);
    return () => clearInterval(timer);
  });

  async function music(command: string) {
    const r = await companion.call({ op: "music", text: command });
    took(r.view);
    if (r.response?.home) home = r.response.home;
  }

  function ask() {
    const text = question.trim();
    if (!text) return;
    question = "";
    onnook(null, text);
  }

  const toneColor = (tone: string) => (tone === "mint" ? "var(--mint)" : tone === "amber" ? "var(--amber)" : tone === "coral" ? "var(--coral)" : "var(--iris)");
  const time = (s: number) => new Date(s * 1000).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
</script>

<div class="home">
  <div class="scroll">
    <div class="hello">
      <p class="faint date">{now.toLocaleDateString(locale(), { weekday: "long", day: "numeric", month: "long" })}</p>
      <h2>{greeting(now.getHours())}</h2>
    </div>

    <div class="tiles">
      <button class="tile" onclick={() => ontab("agents")}><strong style:color={waiting.length ? "var(--amber)" : undefined}>{needingYou(view.sessions)}</strong><span>{tr("Wacht op je", "Waiting for you")}</span></button>
      <button class="tile" onclick={() => ontab("agents")}><strong>{working}</strong><span>{tr("Aan het werk", "Working")}</span></button>
      {#if has(view, Feature.inbox) && may(view, "chats")}
        <button class="tile" onclick={() => ontab("chats")}><strong>{unreadChats(inbox)}</strong><span>{tr("Ongelezen", "Unread")}</span></button>
      {/if}
    </div>

    {#if waiting.length || unread.length || home?.lines.length}
      <section class="card">
        <h3>{tr("Voor jou", "For you")}</h3>
        {#each waiting as s (s.id)}
          <button class="line" onclick={() => onsession(s.id)}>
            <span class="mark" style:background="var(--amber)"></span>
            <span class="text"><strong>{s.title}</strong><span class="faint">{s.items[0]?.title ?? s.agent}</span></span>
          </button>
        {/each}
        {#each unread.slice(0, 5) as c (c.id)}
          <button class="line" onclick={() => onchat(c.id)}>
            <span class="mark" style:background="var(--blue)"></span>
            <span class="text"><strong>{c.name}</strong><span class="faint">{c.appName} · {c.preview}</span></span>
            <span class="count">{c.unread}</span>
          </button>
        {/each}
        {#each home?.lines ?? [] as l (l.id)}
          <div class="line static">
            <span class="mark" style:background={toneColor(l.tone)}></span>
            <span class="text"><strong>{l.title}</strong>{#if l.subtitle}<span class="faint">{l.subtitle}</span>{/if}</span>
          </div>
        {/each}
      </section>
    {/if}

    {#if home?.events.length}
      <section class="card">
        <h3>{tr("Agenda", "Agenda")}</h3>
        {#each home.events as e (e.id)}
          <div class="line static">
            <Icon name="calendar" size={15} />
            <span class="text"><strong>{e.title}</strong><span class="faint">{time(e.start)}–{time(e.end)}{e.location ? ` · ${e.location}` : ""}</span></span>
          </div>
        {/each}
      </section>
    {/if}

    {#if home?.track}
      <section class="card">
        <h3>{tr("Speelt nu", "Now playing")}</h3>
        <div class="track">
          <span class="text"><strong>{home.track.title}</strong><span class="faint">{home.track.artist}{home.track.app ? ` · ${home.track.app}` : ""}</span></span>
          {#if canMusic}
            <div class="controls">
              <button class="ghost" onclick={() => music("previous")} aria-label={tr("Vorige", "Previous")}>⏮</button>
              <button class="ghost" onclick={() => music("playpause")} aria-label={home.track.playing ? tr("Pauzeer", "Pause") : tr("Speel af", "Play")}>{home.track.playing ? "⏸" : "▶"}</button>
              <button class="ghost" onclick={() => music("next")} aria-label={tr("Volgende", "Next")}>⏭</button>
            </div>
          {/if}
        </div>
      </section>
    {/if}

    {#if home?.accounts.some((a) => a.limits.length)}
      <section class="card">
        <h3>{tr("Limieten", "Limits")}</h3>
        {#each home.accounts.filter((a) => a.limits.length) as a (a.id)}
          <div class="account">
            <span class="faint small">{a.agent}{a.account ? ` · ${a.account}` : ""}</span>
            {#each a.limits as limit (limit.label)}
              <div class="limit">
                <span class="label">{limit.label}</span>
                <span class="bar"><span style:width="{Math.min(100, Math.max(0, limit.percent))}%" style:background={limit.percent >= 90 ? "var(--coral)" : limit.percent >= 70 ? "var(--amber)" : "var(--mint)"}></span></span>
                <span class="faint small pct">{Math.round(limit.percent)}%{limit.resetsAt ? ` · ${resetsIn(limit.resetsAt)}` : limit.note ? ` · ${limit.note}` : ""}</span>
              </div>
            {/each}
          </div>
        {/each}
      </section>
    {/if}

    {#if canChat}
      <section class="card">
        <h3>{tr("Gesprekken met Nook", "Chats with Nook")}</h3>
        {#if noBrain}<p class="faint small">{tr("Op je computer is Nooks brein nog niet ingesteld.", "Nook's brain isn't set up on your computer yet.")}</p>{/if}
        {#each chats.slice(0, 6) as c (c.id)}
          <button class="line" onclick={() => onnook(c.id)}>
            <Icon name="chat" size={15} />
            <span class="text"><strong>{c.title || tr("Gesprek", "Chat")}</strong><span class="faint">{c.busy ? tr("Nook schrijft…", "Nook is writing…") : c.preview}</span></span>
            <span class="faint small">{shortTime(c.updated)}</span>
          </button>
        {:else}
          {#if !noBrain}<p class="faint small">{tr("Nog geen gesprekken.", "No chats yet.")}</p>{/if}
        {/each}
        {#if home?.suggestions.length}
          <div class="chips">
            {#each home.suggestions.slice(0, 4) as s (s)}<button class="chip" onclick={() => onnook(null, s)}>{s}</button>{/each}
          </div>
        {/if}
      </section>
    {/if}
  </div>

  {#if canChat}
    <div class="composer">
      <div class="field">
        <textarea rows="1" placeholder={tr("Vraag Nook iets", "Ask Nook something")} bind:value={question} onkeydown={(e) => e.key === "Enter" && !e.shiftKey && (e.preventDefault(), ask())}></textarea>
        <button class="primary send" disabled={!question.trim()} onclick={ask} aria-label={tr("Verstuur", "Send")}><Icon name="arrow" size={18} /></button>
      </div>
    </div>
  {/if}
</div>

<style>
  .home { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding: var(--space-12) var(--space-16) var(--space-24); display: flex; flex-direction: column; gap: var(--space-12); }
  .hello h2 { margin: 0; font: var(--text-display); }
  .date { margin: 0; font: var(--text-detail); text-transform: capitalize; }
  .tiles { display: flex; gap: var(--space-8); }
  .tile { flex: 1; display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-2); padding: var(--space-12); border-radius: var(--radius-card); background: var(--surface); border: 1px solid var(--line2); min-height: 64px; }
  .tile strong { font: var(--text-display); }
  .tile span { font: var(--text-detail); color: var(--text2); }
  .card { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-12); border-radius: var(--radius-panel); background: var(--surface); border: 1px solid var(--line2); }
  h3 { margin: 0 0 var(--space-4); font: var(--text-label); color: var(--text2); text-transform: uppercase; letter-spacing: 0.04em; }
  .line { display: flex; align-items: center; gap: var(--space-8); text-align: left; background: none; border: none; padding: var(--space-6) var(--space-4); min-height: 44px; border-radius: var(--radius-control); width: 100%; color: inherit; }
  button.line:active { background: var(--row-hover); }
  .mark { width: 8px; height: 8px; border-radius: 50%; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .text strong { font: var(--text-control); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .text span { font: var(--text-detail); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .count { min-width: 20px; height: 20px; padding: 0 var(--space-6); border-radius: var(--radius-pill); background: var(--blue); color: var(--ink); font: var(--text-caption); display: inline-flex; align-items: center; justify-content: center; }
  .track { display: flex; align-items: center; gap: var(--space-8); }
  .controls { display: flex; }
  .controls button { min-width: 44px; min-height: 44px; font: var(--text-title); }
  .account { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-4) 0; }
  .limit { display: grid; grid-template-columns: minmax(0, 1fr) 90px; grid-template-areas: "label pct" "bar bar"; gap: var(--space-2) var(--space-8); }
  .label { grid-area: label; font: var(--text-detail); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pct { grid-area: pct; text-align: right; }
  .bar { grid-area: bar; height: 6px; border-radius: var(--radius-pill); background: var(--line2); overflow: hidden; }
  .bar span { display: block; height: 100%; border-radius: var(--radius-pill); }
  .small { font: var(--text-detail); }
  p { margin: 0; }
  .chips { display: flex; flex-wrap: wrap; gap: var(--space-6); padding-top: var(--space-6); }
  .chip { border-radius: var(--radius-pill); min-height: 36px; padding: 0 var(--space-12); font: var(--text-detail); }
  .composer { border-top: 1px solid var(--line); padding: var(--space-8) var(--space-12) var(--space-12); }
  .field { display: flex; gap: var(--space-8); align-items: flex-end; background: var(--composer); border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); }
  .field textarea { flex: 1; resize: none; min-height: 36px; max-height: 120px; border: none; background: transparent; padding: var(--space-8) 0; field-sizing: content; }
  .send { width: 40px; height: 40px; border-radius: 50%; padding: 0; display: flex; align-items: center; justify-content: center; flex: none; }
</style>
