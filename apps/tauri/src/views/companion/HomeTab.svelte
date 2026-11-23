<script lang="ts">
  // The Nook tab of the iPhone app (`ChatListView`): the header, the date and a greeting, what waits on you, works and is
  // unread as tiles, For you (the sessions that need you and the unread chats, a tap away), Nook's recent chats, and a
  // box to ask Nook something. With no chats yet it offers where to start.
  import {
    companion, has, homeGreeting, may, needsYouState, nookGroupTitle, nookMatches, nookSections, relative, unreadChats, writingWaits, Feature,
    type ChatDigest, type ClientView, type CompanionTab, type HomeDigest, type InboxChatDigest, type NookChatAction, type SessionDigest,
  } from "../../lib/companion";
  import { nookAct, nookMenu } from "./nook-chats";
  import type { ChatConfirm } from "./chat-actions";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import Dialog from "../../components/ui/Dialog.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import { untrack } from "svelte";
  import { locale, tr } from "../../lib/i18n.svelte";
  import { greeting } from "../../lib/companion";
  import { rankBy } from "../../lib/attention-rank";
  import PanelHeader from "./ui/PanelHeader.svelte";
  import ConnectionLine from "./ui/ConnectionLine.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import StatusPill from "../../components/ui/StatusPill.svelte";
  import PulseDot from "../../components/ui/PulseDot.svelte";
  import NookMark from "./ui/NookMark.svelte";
  import Banner from "../../components/ui/Banner.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import OfflineStrip from "./ui/OfflineStrip.svelte";

  let { view, inbox, conversations, archived = 0, took, onrefresh, onorb, oncomputers, ongear, onsession, onchat, onnook, ontab }: {
    view: ClientView;
    inbox: InboxChatDigest[];
    conversations: ChatDigest[];
    /** How many conversations wait in the archive (`nookChats`). */
    archived?: number;
    took?: (v: ClientView) => void;
    onrefresh?: () => void;
    onorb: (r: DOMRect) => void;
    /** The quick switcher under the title, with several computers paired. */
    oncomputers?: (r: DOMRect) => void;
    ongear: () => void;
    onsession: (id: string) => void;
    onchat: (id: string) => void;
    onnook: (id: string | null, ask?: string) => void;
    ontab: (tab: CompanionTab) => void;
  } = $props();

  let question = $state("");
  let header = $state<HTMLDivElement | null>(null);
  const now = new Date();
  const canChat = $derived(has(view, Feature.chat) && may(view, "nookChat"));
  const chatsAllowed = $derived(has(view, Feature.inbox) && may(view, "chats"));
  let home = $state<HomeDigest | null>(null);
  const needs = (s: SessionDigest) => s.items.length > 0 || needsYouState(s.attention);
  // What waits on you in the shared ranking's order (the Mac's `AttentionScorer`): a permission request before a
  // question, a question before a failure, the one that waited longer first.
  const waiting = $derived(rankBy(view.sessions.filter(needs).sort((a, b) => b.updated - a.updated), (s) => ({
    source: "agents", id: s.id, app: s.agent, subject: s.id, since: s.updated * 1000,
    needsYou: s.attention === "approval" ? "approval" : s.attention === "input" || s.items.length ? "question" : "failure",
  }), new Map(), Date.now()));
  const working = $derived(view.sessions.filter((s) => s.attention === "working" && !needs(s)).length);
  const unread = $derived(chatsAllowed ? inbox.filter((c) => c.unread > 0).sort((a, b) => b.last - a.last) : []);
  const forYou = $derived([...waiting.map((s) => ({ kind: "session" as const, s })), ...unread.map((c) => ({ kind: "chat" as const, c }))].slice(0, 6));
  const showOverview = $derived(view.sessions.length > 0 || conversations.length > 0 || (chatsAllowed && inbox.length > 0) || !!home);
  const calm = $derived(!waiting.length && !working && !unread.length);
  const fallback = [tr("Wat staat er vandaag in mijn agenda?", "What’s on my calendar today?"), tr("Vat mijn ongelezen mail samen.", "Summarize my unread mail."), tr("Wat hebben mijn agents vandaag gedaan?", "What did my agents do today?")];

  // The Mac's home (`home`): its For you rows, the agenda, the limits, what plays and its starters. Read when the tab
  // shows and every minute after; the player's buttons answer with it.
  const homeAllowed = $derived(has(view, Feature.home) && may(view, "read"));
  async function loadHome() {
    if (!homeAllowed || view.phase !== "connected" || document.visibilityState !== "visible") return;
    const r = await companion.call({ op: "home" });
    if (r.response?.home) home = r.response.home;
  }
  $effect(() => {
    if (!homeAllowed || view.phase !== "connected") return;
    loadHome();
    const timer = setInterval(loadHome, 60_000);
    return () => clearInterval(timer);
  });
  const music = $derived(has(view, Feature.music) && may(view, "music"));
  async function play(command: "playpause" | "next" | "previous") {
    const r = await companion.call({ op: "music", text: command });
    if (r.response?.home) home = r.response.home;
    else took?.(r.view);
  }
  // The computer's Nook update (`installUpdate`): Install, or Restart now when it waits for agents. Installing stops
  // what the agents there do, so it needs the right to operate.
  const offer = $derived(has(view, Feature.installUpdate) && may(view, "operate") ? home?.update : undefined);
  async function installUpdate() {
    const r = await companion.call({ op: "installUpdate" });
    if (r.response?.home) home = r.response.home;
    const said = ({
      installing: tr("Nook op je computer installeert de update en start daarna vanzelf weer.", "Nook on your computer is installing the update. It starts again by itself."),
      waiting: tr("Er werken nog agents op je computer. Tik op Nu herstarten om ze te stoppen en de update af te maken.", "Agents on your computer are still working. Tap Restart now to stop them and finish the update."),
      restarting: tr("Nook op je computer herstart in de nieuwe versie.", "Nook on your computer is restarting into the new version."),
      blocked: tr("Voor deze update moet je op je computer iets kiezen. Nook heeft hem daar geopend.", "This update needs a choice on your computer. Nook opened it there."),
      none: tr("Nook op je computer heeft nog geen update klaarstaan.", "Nook on your computer has no update ready yet."),
    } as Record<string, string>)[r.response?.message ?? ""] ?? tr("Nook op je computer kan zichzelf niet bijwerken.", "Nook on your computer cannot update itself.");
    took?.({ ...r.view, notice: said });
  }
  const offerStatus = $derived(!offer ? "" : offer.state === "installing"
    ? (offer.progress != null ? tr("Downloaden {percent}%", "Downloading {percent}%", { percent: String(Math.round(offer.progress * 100)) }) : tr("Installeren…", "Installing…"))
    : offer.state === "readyToRestart" ? tr("Wacht op agents", "Waiting for agents")
    : offer.state === "failed" ? tr("Mislukt", "Failed") : tr("Klaar", "Ready"));
  const offerAction = $derived(!offer || offer.state === "installing" ? "" : offer.state === "readyToRestart" ? tr("Nu herstarten", "Restart now")
    : offer.state === "failed" ? tr("Opnieuw proberen", "Try again") : tr("Installeren", "Install"));
  const suggestions = $derived(home?.suggestions.length ? home.suggestions.slice(0, 4) : fallback);
  const macLines = $derived(home ? home.lines.slice(0, 6) : null);
  const todayEnd = $derived(new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1).getTime() / 1000);
  const todays = $derived(home ? home.events.filter((e) => e.start < todayEnd) : []);
  const limits = $derived(home ? home.accounts.flatMap((a) => {
    const top = [...a.limits].sort((x, y) => y.percent - x.percent)[0];
    const several = home!.accounts.filter((b) => b.agent === a.agent).length > 1;
    return top ? [{ id: a.id, name: several ? `${a.agent} · ${a.account}` : a.agent, percent: top.percent }] : [];
  }).slice(0, 3) : []);
  const time = (s: number) => new Date(s * 1000).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });

  // The list as the Mac's Nook tab shows it (`nookChats`): what asks for you on a card, pinned, then by age, a search
  // (the Mac sends its whole open list, so the same words find the same here), the archive at the foot.
  const likeTheMac = $derived(has(view, Feature.nookChats));
  let query = $state("");
  const searching = $derived(query.trim().length > 0);
  const sections = $derived(nookSections(conversations.filter((c) => nookMatches(c, query)), searching));
  let showArchive = $state(false);
  let archive = $state<ChatDigest[]>([]);
  async function loadArchive() {
    const r = await companion.call({ op: "chatSearch", text: query.trim(), allow: true });
    archive = r.response?.conversationsFound ?? [];
  }
  $effect(() => {
    if (!showArchive) return;
    void query; void archived;
    const timer = setTimeout(() => untrack(loadArchive), 300);
    return () => clearTimeout(timer);
  });

  let menu = $state<{ chat: ChatDigest; anchor: DOMRect } | null>(null);
  let confirming = $state<ChatConfirm | null>(null);
  let renaming = $state<ChatDigest | null>(null);
  let newName = $state("");
  async function run(chat: ChatDigest, action: NookChatAction) {
    const r = await nookAct(chat.id, action);
    took?.(r.view);
    onrefresh?.();
    if (showArchive) loadArchive();
  }
  const menuSections = $derived<MenuItem[][]>(menu ? nookMenu(menu.chat, (a) => menu && run(menu.chat, a), (c) => (confirming = c), () => {
    if (!menu) return;
    renaming = menu.chat;
    newName = menu.chat.title;
  }) : []);
  let press: ReturnType<typeof setTimeout> | undefined;
  let held = false;
  function down(e: PointerEvent, chat: ChatDigest) {
    held = false;
    if (!likeTheMac) return;
    const el = e.currentTarget as HTMLElement;
    press = setTimeout(() => { held = true; menu = { chat, anchor: el.getBoundingClientRect() }; }, 450);
  }
  const up = () => clearTimeout(press);

  function toneColor(tone: string): string {
    return tone === "amber" ? "var(--amber)" : tone === "coral" ? "var(--coral)" : tone === "mint" ? "var(--mint)" : "var(--iris)";
  }

  function ask(text: string) {
    question = "";
    onnook(null, text);
  }
</script>

<div class="tab">
  <div class="scroll">
    <div bind:this={header}>
      <PanelHeader title="Nook" {view} onorb={() => header && onorb((header.querySelector(".orb") as HTMLElement).getBoundingClientRect())} {oncomputers} {ongear} />
    </div>
    <div class="top">
      <ConnectionLine {view} />
      {#if showOverview}
        <div class="overview">
          <div class="hello">
            <span class="date">{now.toLocaleDateString(locale(), { weekday: "long", day: "numeric", month: "long" })}</span>
            <h2>{macLines ? homeGreeting(now.getHours(), macLines.length) : greeting(now.getHours())}</h2>
          </div>
          {#if calm && !macLines?.length}
            <p class="calm"><span style:color="var(--mint)"><Ico name="circle-check" size={16} /></span>{tr("Alles rustig. Er hoeft nu niets van je.", "All calm. Nothing needs you right now.")}</p>
          {:else if !calm}
            <div class="tiles">
              {#if waiting.length}{@render tile(waiting.length, tr("Wacht op jou", "Waiting on you"), "hand", "var(--amber)", true, () => ontab("agents"))}{/if}
              {#if working}{@render tile(working, tr("Aan het werk", "Working"), "circle-dashed", "var(--blue)", false, () => ontab("agents"))}{/if}
              {#if unread.length}{@render tile(unreadChats(inbox), tr("Ongelezen chats", "Unread chats"), "messages-square", "var(--text2)", false, () => ontab("chats"))}{/if}
            </div>
          {/if}
          {#if macLines?.length}
            <div class="foryou">
              <span class="label">{tr("Voor jou", "For you")}</span>
              <div class="card">
                {#each macLines as line, i (line.id)}
                  {#if i > 0}<div class="sep"></div>{/if}
                  <button class="fy row-press" onclick={() => line.icon.startsWith("agent:") && ontab("agents")}>
                    <span class="homelogo" style:color={toneColor(line.tone)}>{#if line.icon.startsWith("agent:")}<AgentMark agent={line.icon.slice(6)} size={18} />{:else}<Ico name="sparkles" size={15} />{/if}</span>
                    <span class="text"><strong>{line.title}</strong>{#if line.subtitle}<span>{line.subtitle}</span>{/if}</span>
                  </button>
                {/each}
              </div>
            </div>
          {:else if forYou.length}
            <div class="foryou">
              <span class="label">{tr("Voor jou", "For you")}</span>
              <div class="card">
                {#each forYou as row, i (row.kind === "session" ? row.s.id : row.c.id)}
                  {#if i > 0}<div class="sep"></div>{/if}
                  {#if row.kind === "session"}
                    <button class="fy row-press" onclick={() => onsession(row.s.id)}>
                      <span class="homelogo"><AgentMark agent={row.s.agent} size={18} /></span>
                      <span class="text"><strong>{row.s.title}</strong><span>{row.s.items[0]?.title ?? row.s.folder}</span></span>
                      <StatusPill attention={row.s.items[0]?.kind === "approval" ? "approval" : row.s.items[0]?.kind === "question" ? "input" : row.s.attention} />
                    </button>
                  {:else}
                    <button class="fy row-press" onclick={() => onchat(row.c.id)}>
                      <InboxAvatar id={row.c.id} name={row.c.name} size={32} badge={false} />
                      <span class="text"><strong>{row.c.name}</strong><span>{row.c.preview}</span></span>
                      <span class="unread">{row.c.unread}</span>
                    </button>
                  {/if}
                {/each}
              </div>
            </div>
          {/if}
        </div>
      {/if}
    </div>

    {#if home && (home.events.length || limits.length || home.track || offer)}
      <div class="glance">
        <span class="label pad16">{tr("In één oogopslag", "At a glance")}</span>
        <div class="cards">
          {#if offer}
            <div class="gcard">
              <span class="ghead"><Ico name="circle-arrow-down" size={12} /><span>{tr("Nook-update", "Nook update")}</span><span class="sp"></span><small>{offerStatus}</small></span>
              <span class="track"><strong>Nook {offer.version}</strong>{#if offer.changes}<span>{tr("{count} wijzigingen", "{count} changes", { count: String(offer.changes) })}</span>{/if}</span>
              {#if offerAction}<button class="update press" onclick={installUpdate}>{offerAction}</button>{/if}
            </div>
          {/if}
          {#if home.events.length}
            <div class="gcard">
              <span class="ghead"><Ico name="calendar" size={12} /><span>{tr("Agenda", "Agenda")}</span><span class="sp"></span>{#if todays.length}<small>{tr("{count} vandaag", "{count} today", { count: String(todays.length) })}</small>{/if}</span>
              {#each (todays.length ? todays.slice(0, 3) : home.events.slice(0, 2)) as e (e.id)}
                <button class="event press" onclick={() => ask(tr("Bereid me voor op {title}", "Prepare me for {title}", { title: e.title }))}><span class="at">{time(e.start)}</span><strong>{e.title}</strong></button>
              {/each}
            </div>
          {/if}
          {#if limits.length}
            <button class="gcard press" onclick={ongear}>
              <span class="ghead"><Ico name="gauge" size={12} /><span>{tr("Limieten", "Limits")}</span></span>
              {#each limits as l (l.id)}
                <span class="limit"><span class="lname">{l.name}</span><span class="pct" class:hot={l.percent >= 80}>{Math.round(l.percent)}%</span></span>
                <span class="bar"><span style:width="{Math.min(100, Math.max(0, l.percent))}%" class:hot={l.percent >= 80}></span></span>
              {/each}
            </button>
          {/if}
          {#if home.track}{@const t = home.track}
            <div class="gcard">
              <span class="ghead"><Ico name="music" size={12} /><span>{t.app || tr("Speelt nu", "Now playing")}</span><span class="sp"></span><small>{t.playing ? tr("Speelt", "Playing") : tr("Gepauzeerd", "Paused")}</small></span>
              <span class="track"><strong>{t.title}</strong><span>{t.artist}</span></span>
              {#if music}
                <span class="player">
                  <button class="press" aria-label={tr("Vorig nummer", "Previous track")} onclick={() => play("previous")}><Ico name="skip-back" size={15} /></button>
                  <button class="press" aria-label={t.playing ? tr("Pauze", "Pause") : tr("Speel af", "Play")} onclick={() => play("playpause")}><Ico name={t.playing ? "pause" : "play"} size={15} /></button>
                  <button class="press" aria-label={tr("Volgend nummer", "Next track")} onclick={() => play("next")}><Ico name="skip-forward" size={15} /></button>
                </span>
              {/if}
            </div>
          {/if}
        </div>
      </div>
    {/if}

    {#if !has(view, Feature.chat)}
      <div class="pad"><Banner icon="circle-arrow-down">{tr("Werk Nook op je Mac bij om vanaf je telefoon met Nook te chatten.", "Update Nook on your Mac to chat with Nook from your phone.")}</Banner></div>
    {:else if canChat}
      {#if !conversations.length}
        <div class="asknook">
          <NookMark size={44} />
          <h2>{tr("Vraag Nook wat je wilt", "Ask Nook anything")}</h2>
          <p>{tr("Je agenda, mail, notities of het web. Plannen en concepten wachten op je goedkeuring op je Mac.", "Your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.")}</p>
          <div class="grid">
            {#each suggestions as s (s)}
              <button class="suggestion row-press" onclick={() => ask(s)}><span class="spark"><Ico name="sparkles" size={11} /></span><span>{s}</span></button>
            {/each}
          </div>
        </div>
      {:else if likeTheMac}
        {#if home}
          <div class="starters">
            <span class="label">{tr("Begin met", "Start with")}</span>
            <div class="grid">
              {#each suggestions as s (s)}
                <button class="suggestion row-press" onclick={() => ask(s)}><span class="spark"><Ico name="sparkles" size={11} /></span><span>{s}</span></button>
              {/each}
            </div>
          </div>
        {/if}
        <h3 class="section">{tr("Gesprekken", "Conversations")}</h3>
        {#if conversations.length > 4 || searching}
          <div class="pad search"><SearchField bind:value={query} placeholder={tr("Zoek in gesprekken", "Search conversations")} /></div>
        {/if}
        {#if searching && !sections.attention.length && !sections.groups.length}<p class="none">{tr("Niets gevonden", "No matches")}</p>{/if}
        {#if sections.attention.length}
          <div class="chats attention">{#each sections.attention as c (c.id)}{@render row(c)}{/each}</div>
        {/if}
        {#each sections.groups as g (g.group)}
          <h3 class="section">{nookGroupTitle(g.group)}</h3>
          <div class="chats">{#each g.chats as c (c.id)}{@render row(c)}{/each}</div>
        {/each}
        {#if archived > 0}
          <button class="shelf row-press" onclick={() => (showArchive = !showArchive)} aria-expanded={showArchive}>
            <Ico name="archive" size={13} /><span>{tr("Gearchiveerd", "Archived")}</span><small>{archived}</small><span class="sp"></span>
            <span class="chev" class:open={showArchive}><Ico name="chevron-right" size={11} stroke={3} /></span>
          </button>
          {#if showArchive}
            <div class="chats">{#each archive as c (c.id)}{@render row(c)}{/each}</div>
          {/if}
        {/if}
      {:else}
        <h3 class="section">{tr("Recent", "Recent")}</h3>
        <div class="chats">
          {#each conversations as c (c.id)}{@render row(c)}{/each}
        </div>
      {/if}
    {/if}
  </div>
  {#if canChat}
    <div class="dock">
      <OfflineStrip {view} />
      <SessionComposer bind:value={question} placeholder={tr("Vraag Nook", "Ask Nook")} onsend={ask} canSend={view.phase !== "offline" || writingWaits(view)} />
    </div>
  {/if}
</div>

{#snippet row(c: ChatDigest)}
  <button class="chatrow row-press" onclick={() => !held && onnook(c.id)} onpointerdown={(e) => down(e, c)} onpointerup={up} onpointerleave={up} onpointercancel={up} oncontextmenu={(e) => likeTheMac && e.preventDefault()}>
    <span class="l1">{#if c.unread && !c.busy && !c.waiting}<span class="dot" aria-label={tr("Ongelezen", "Unread")}></span>{/if}<strong>{c.title || tr("Nieuwe chat", "New chat")}</strong>
      {#if c.pinned}<span class="pin"><Ico name="pin" size={11} /></span>{/if}
      {#if c.waiting}<StatusPill attention="input" />{:else}<span class="when">{relative(c.updated)}</span>{/if}
    </span>
    {#if c.busy}<span class="l2 busy"><PulseDot size={6} />{tr("Aan het schrijven…", "Writing…")}{#if c.queued?.length}<span>· {tr("{count} wachten", "{count} waiting", { count: String(c.queued.length) })}</span>{/if}</span>
    {:else}<span class="l2">{c.preview}</span>{/if}
  </button>
{/snippet}

{#if menu}<Menu sections={menuSections} anchor={menu.anchor} title={menu.chat.title} onclose={() => (menu = null)} />{/if}
{#if confirming}{@const c = confirming}
  <Dialog title={c.title} message={c.message} onclose={() => (confirming = null)}
    buttons={[{ label: c.button, destructive: true, onselect: c.run }, { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} }]} />
{/if}
{#if renaming}{@const chat = renaming}
  <Dialog title={tr("Hernoem gesprek", "Rename conversation")} bind:field={newName} placeholder={tr("Naam", "Name")} onclose={() => (renaming = null)}
    buttons={[{ label: tr("Annuleer", "Cancel"), onselect: () => {} }, { label: tr("Hernoem", "Rename"), bold: true, onselect: () => {
      const name = newName.trim().slice(0, 80);
      if (name && name !== chat.title) run(chat, { kind: "rename", text: name });
    } }]} />
{/if}

{#snippet tile(count: number, title: string, icon: string, tint: string, urgent: boolean, onclick: () => void)}
  <button class="tile press" {onclick} style:border-color={urgent ? `color-mix(in srgb, ${tint} 35%, transparent)` : undefined}
    style:background-image="linear-gradient(135deg, color-mix(in srgb, {tint} {urgent ? 14 : 6}%, transparent), transparent 70%)">
    <span class="tilehead"><span style:color={tint}><Ico name={icon} size={13} stroke={2.4} /></span><span class="sp"></span><span class="chev"><Ico name="chevron-right" size={10} stroke={3} /></span></span>
    <span class="count">{count}</span>
    <span class="tiletitle">{title}</span>
  </button>
{/snippet}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px; }
  .pad { padding: 12px 16px; }
  .overview { display: flex; flex-direction: column; gap: 12px; padding-top: 8px; }
  .hello { display: flex; flex-direction: column; gap: 2px; }
  .date { font: var(--pt-label); color: var(--text3); }
  h2 { margin: 0; font: var(--pt-heading); color: var(--paper); }
  .calm { margin: 0; display: flex; align-items: center; gap: 6px; font: var(--pt-body); color: var(--text2); }
  .tiles { display: flex; gap: 8px; }
  .tile { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; padding: 12px; border-radius: 12px; background-color: var(--surface) !important; border: 1px solid var(--line2) !important; text-align: left; }
  .tilehead { display: flex; align-items: center; }
  .sp { flex: 1; }
  .chev { color: var(--text3); display: inline-flex; }
  .count { font: 600 26px/1.1 ui-rounded, var(--font); font-variant-numeric: tabular-nums; color: var(--paper); }
  .tiletitle { font: var(--pt-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .foryou { display: flex; flex-direction: column; gap: 6px; }
  .label { font: var(--pt-label); color: var(--text3); }
  .card { background: var(--surface); border: 1px solid var(--line2); border-radius: 12px; padding: 4px 0; }
  .sep { height: 0.5px; background: var(--hairline); margin-left: 52px; }
  .fy { width: 100%; display: flex; align-items: center; gap: 8px; padding: 6px 8px; text-align: left; }
  .homelogo { width: 32px; height: 32px; border-radius: 9px; background: rgba(255, 255, 255, 0.05); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .text strong { font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .text span { font: var(--pt-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .unread { min-width: 20px; height: 20px; padding: 0 6px; border-radius: 999px; background: var(--paper); color: var(--ink); font: var(--pt-caption); font-variant-numeric: tabular-nums; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; }
  .asknook { display: flex; flex-direction: column; gap: 16px; padding: 24px 16px 0; }
  .asknook p { margin: 0; font: var(--pt-body); color: var(--text2); }
  .asknook h2 { font: var(--pt-display); }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .suggestion { display: flex; align-items: center; gap: 8px; padding: 8px; min-height: 52px; background: var(--field) !important; border-radius: 12px !important; text-align: left; font: var(--pt-body) !important; color: var(--text-strong) !important; }
  .spark { width: 26px; height: 26px; border-radius: 7.3px; background: rgba(161, 161, 161, 0.12); color: var(--text2); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .section { margin: 0; padding: 16px 28px 8px; font: var(--pt-label); color: var(--text3); }
  .chats { display: flex; flex-direction: column; gap: 2px; padding: 0 8px; }
  .chatrow { display: flex; flex-direction: column; gap: 4px; padding: 10px 12px; text-align: left; }
  .l1 { display: flex; align-items: center; gap: 8px; }
  .l1 strong { flex: 1; min-width: 0; font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { font: var(--pt-detail); color: var(--text3); flex: none; }
  .l2 { font: var(--pt-detail); color: var(--text3); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .l2.busy { display: flex; align-items: center; gap: 6px; color: var(--text2); }
  .glance { display: flex; flex-direction: column; gap: 6px; padding-top: 20px; }
  .pad16 { padding: 0 16px; }
  .cards { display: flex; gap: 8px; overflow-x: auto; padding: 0 16px; scrollbar-width: none; }
  .cards::-webkit-scrollbar { display: none; }
  .gcard { flex: none; width: 236px; display: flex; flex-direction: column; gap: 8px; padding: 12px; border-radius: 12px; background: var(--field) !important; text-align: left; }
  .ghead { display: flex; align-items: center; gap: 6px; color: var(--text3); }
  .ghead span:not(.sp) { font: var(--pt-label); color: var(--text2); }
  .ghead small { font: var(--pt-caption); color: var(--text3); }
  .event { display: flex; align-items: baseline; gap: 8px; min-height: 28px; text-align: left; }
  .event .at { font: var(--pt-detail); color: var(--text2); font-variant-numeric: tabular-nums; }
  .event strong, .track strong { font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .update { align-self: flex-start; min-height: 36px; padding: 0 var(--space-12); border: none; border-radius: var(--radius-control); background: var(--smoke); color: var(--paper); font: var(--pt-strong); }
  .track { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .track span { font: var(--pt-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .player { display: flex; gap: 12px; }
  .player button { width: 44px; height: 36px; border-radius: 8px; background: var(--smoke) !important; color: var(--paper) !important; display: inline-flex; align-items: center; justify-content: center; }
  .limit { display: flex; align-items: center; gap: 6px; }
  .lname { flex: 1; min-width: 0; font: var(--pt-detail); color: var(--text-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pct { font: var(--pt-caption); color: var(--text2); font-variant-numeric: tabular-nums; }
  .pct.hot { color: var(--amber); }
  .bar { height: 4px; border-radius: 2px; background: var(--smoke); overflow: hidden; display: block; }
  .bar span { display: block; height: 100%; background: var(--iris); border-radius: 2px; }
  .bar span.hot { background: var(--amber); }
  .starters { display: flex; flex-direction: column; gap: 6px; padding: 20px 16px 0; }
  .search { padding-top: 0; padding-bottom: 4px; }
  .none { margin: 0; padding: 8px 28px; font: var(--pt-detail); color: var(--text2); }
  .attention { margin: 0 8px 8px; padding: 4px 0; background: var(--surface); border: 1px solid var(--line2); border-radius: 12px; }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--iris); flex: none; }
  .pin { color: var(--text3); display: inline-flex; }
  .shelf { display: flex; align-items: center; gap: 8px; min-height: 44px; margin: 12px 8px 0; padding: 0 12px; color: var(--text2); text-align: left; width: calc(100% - 16px); }
  .shelf span:not(.sp):not(.chev) { font: var(--pt-strong); color: var(--text-strong); }
  .shelf small { font: var(--pt-caption); color: var(--text3); }
  .chev { display: inline-flex; transition: transform 0.2s; color: var(--text3); }
  .chev.open { transform: rotate(90deg); }
  .dock { padding: 8px 12px; background: linear-gradient(transparent, var(--canvas) 30%); }
</style>
