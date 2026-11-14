<script lang="ts">
  // The phone side of the companion, laid out as Nook Companion on the iPhone: the computer's three tabs (Nook, Agents,
  // Chats) with what waits as a count on each, a session as its whole conversation, a new session, Nook's own chats and
  // the Chats tab. Only what the computer lists (`features`) and allows this phone (`scopes`) shows; a computer that
  // lists nothing (Nook on Windows or Linux, an older Mac) gets the Agents list with approve, answer, send and stop.
  import { untrack } from "svelte";
  import { companion, has, may, needingYou, tabsFor, unreadChats, Feature, type CompanionTab, type ClientView, type InboxChatDigest } from "../../lib/companion";
  import { onBack } from "../../lib/mobile";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";
  import Pairing from "./Pairing.svelte";
  import HomeTab from "./HomeTab.svelte";
  import AgentsTab from "./AgentsTab.svelte";
  import ChatsTab from "./ChatsTab.svelte";
  import SessionDetail from "./SessionDetail.svelte";
  import NewSession from "./NewSession.svelte";
  import NookChat from "./NookChat.svelte";
  import InboxChat from "./InboxChat.svelte";

  type Screen =
    | { kind: "session"; id: string }
    | { kind: "new"; task?: string }
    | { kind: "nook"; id: string | null; ask?: string }
    | { kind: "chat"; id: string };

  let view = $state<ClientView | null>(null);
  let tab = $state<CompanionTab>("agents");
  let screen = $state<Screen | null>(null);
  let menu = $state(false);
  let refreshing = $state(false);
  let inbox = $state<InboxChatDigest[]>([]);
  let inboxMessage = $state<string | undefined>(undefined);

  $effect(() => {
    companion.client().then((v) => (view = v));
    companion.refresh().then((v) => (view = v));
    const un = companion.onClient((v) => (view = { ...v, deviceName: view?.deviceName }));
    const visible = () => companion.visible(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", visible);
    visible();
    return () => {
      un.then((f) => f());
      document.removeEventListener("visibilitychange", visible);
    };
  });

  const paired = $derived(!!view && (view.phase === "connected" || view.phase === "offline"));
  const tabs = $derived(tabsFor(view));
  const showInbox = $derived(has(view, Feature.inbox) && may(view, "chats"));

  // The Nook tab first when the computer has one, as on the iPhone; a tab the computer stopped listing falls back.
  let chose = false;
  $effect(() => {
    if (!tabs.includes(tab)) tab = "agents";
    if (!chose && tabs.includes("home") && view?.phase === "connected") {
      chose = true;
      tab = "home";
    }
  });

  // The Chats list, also for the counts on the tabs: when the tab opens and every 20 seconds while paired.
  async function loadInbox() {
    if (!showInbox || view?.phase !== "connected") return;
    const r = await companion.call({ op: "inbox" });
    if (r.response?.inbox) inbox = r.response.inbox;
    inboxMessage = r.response?.message;
  }
  const connected = $derived(view?.phase === "connected");
  $effect(() => {
    if (!showInbox || !connected) return;
    untrack(loadInbox);
    const timer = setInterval(() => document.visibilityState === "visible" && loadInbox(), 20_000);
    return () => clearInterval(timer);
  });

  // The back button closes the menu first, then what is open.
  $effect(() => onBack(() => {
    if (menu) return (menu = false), true;
    if (screen) return (screen = null), true;
    return false;
  }));

  async function act(f: () => Promise<ClientView>) {
    const v = await f();
    view = { ...v, deviceName: view?.deviceName };
  }

  /** Takes the state a call brought back and hands its answer on. */
  function took(v: ClientView) {
    view = { ...v, deviceName: view?.deviceName };
  }

  async function refresh() {
    refreshing = true;
    await act(companion.refresh);
    await loadInbox();
    refreshing = false;
  }

  const counts = $derived<Record<CompanionTab, number>>({ home: 0, agents: needingYou(view?.sessions ?? []), chats: unreadChats(inbox) });
  const tabTitle = (t: CompanionTab) => (t === "home" ? "Nook" : t === "agents" ? tr("Agents", "Agents") : tr("Chats", "Chats"));
</script>

<div class="companion">
  {#if !view}
    <p class="faint pad">{tr("Laden…", "Loading…")}</p>
  {:else if !paired}
    <Pairing {view} onchange={(v) => (view = v)} />
  {:else if screen?.kind === "session"}
    <SessionDetail {view} id={screen.id} onback={() => (screen = null)} {act} {took} />
  {:else if screen?.kind === "new"}
    <NewSession {view} task={screen.task} onback={() => (screen = null)} {took} onstarted={(id) => (screen = id ? { kind: "session", id } : null)} />
  {:else if screen?.kind === "nook"}
    <NookChat {view} id={screen.id} ask={screen.ask} onback={() => (screen = null)} {took} />
  {:else if screen?.kind === "chat"}
    {@const chat = inbox.find((c) => screen?.kind === "chat" && c.id === screen.id) ?? null}
    <InboxChat {view} id={screen.id} {chat} onback={() => { screen = null; loadInbox(); }} {took} />
  {:else}
    <header>
      <button class="ghost who" onclick={() => (menu = !menu)} aria-expanded={menu} aria-label={tr("Menu van {name}", "Menu of {name}", { name: view.macName || "Nook" })}>
        <span class="dot" class:away={view.phase === "offline"}></span>
        <h2>{view.macName || "Nook"}</h2>
        <Icon name="chevron-down" size={14} />
      </button>
      <button class="ghost icon" title={tr("Ververs", "Refresh")} aria-label={tr("Ververs", "Refresh")} disabled={refreshing} onclick={refresh}>↻</button>
    </header>
    {#if menu}
      <div class="menu">
        <p class="faint small">
          {view.phase === "connected" ? tr("Verbonden met {host}", "Connected to {host}", { host: view.host }) : view.reason || tr("Zoeken naar je computer…", "Looking for your computer…")}
        </p>
        <button class="danger" onclick={() => { menu = false; act(async () => companion.unpair()); }}>{tr("Ontkoppel van {name}", "Unpair from {name}", { name: view.macName || tr("deze computer", "this computer") })}</button>
      </div>
    {/if}
    {#if tabs.length > 1}
      <nav class="tabs" aria-label={tr("Tabs van je computer", "Your computer's tabs")}>
        {#each tabs as t (t)}
          <button class:on={tab === t} aria-current={tab === t ? "page" : undefined} onclick={() => (tab = t)}>
            <Icon name={t === "home" ? "home" : t === "agents" ? "agents" : "message"} size={16} />
            <span>{tabTitle(t)}</span>
            {#if counts[t] > 0}<span class="badge">{counts[t]}</span>{/if}
          </button>
        {/each}
      </nav>
    {/if}
    {#if view.phase === "offline"}
      <div class="banner">📡 {view.reason || tr("Zoeken naar je computer…", "Looking for your computer…")}</div>
    {/if}
    <div class="page">
      {#if tab === "home"}
        <HomeTab {view} {inbox} {took}
          onsession={(id) => (screen = { kind: "session", id })}
          onchat={(id) => (screen = { kind: "chat", id })}
          onnook={(id, ask) => (screen = { kind: "nook", id, ask })}
          ontab={(t) => (tab = t)} />
      {:else if tab === "chats"}
        <ChatsTab {inbox} message={inboxMessage} onopen={(id) => (screen = { kind: "chat", id })} />
      {:else}
        <AgentsTab {view} {act} onopen={(id) => (screen = { kind: "session", id })} onnew={() => (screen = { kind: "new" })} />
      {/if}
    </div>
  {/if}
  {#if view?.notice}
    <div class="notice" role="alert">
      <span>{view.notice}</span>
      <button onclick={() => { companion.clearNotice(); if (view) view.notice = null; }}>OK</button>
    </div>
  {/if}
</div>

<style>
  .companion { height: 100%; display: flex; flex-direction: column; min-height: 0; position: relative; }
  header { display: flex; align-items: center; gap: var(--space-4); padding: var(--space-8) var(--space-8) var(--space-4) var(--space-8); }
  .who { flex: 1; min-width: 0; display: flex; align-items: center; gap: var(--space-8); min-height: 44px; justify-content: flex-start; padding: 0 var(--space-8); }
  .who h2 { margin: 0; font: var(--text-heading); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--mint); flex: none; }
  .dot.away { background: var(--amber); }
  .icon { min-width: 44px; min-height: 44px; font: var(--text-heading); }
  .menu { padding: var(--space-8) var(--space-12) var(--space-12); border-bottom: 1px solid var(--line); display: flex; flex-direction: column; gap: var(--space-8); }
  .menu p { margin: 0; }
  .menu button { width: 100%; min-height: 44px; }
  .tabs { display: flex; gap: var(--space-4); padding: 0 var(--space-12) var(--space-8); border-bottom: 1px solid var(--line); }
  .tabs button { flex: 1; min-height: 40px; display: flex; align-items: center; justify-content: center; gap: var(--space-6); border-radius: var(--radius-pill); background: transparent; border: 1px solid transparent; color: var(--text2); font: var(--text-control); }
  .tabs button.on { background: var(--smoke); color: var(--paper); border-color: var(--line2); }
  .badge { min-width: 18px; height: 18px; padding: 0 var(--space-4); border-radius: var(--radius-pill); background: var(--amber); color: var(--ink); font: var(--text-caption); display: inline-flex; align-items: center; justify-content: center; }
  .banner { margin: var(--space-8) var(--space-12) 0; padding: var(--space-8) var(--space-12); border-radius: var(--radius-card); background: var(--field); border: 1px solid var(--line2); color: var(--amber); font: var(--text-detail); }
  .page { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .pad { padding: var(--space-16); }
  .small { font: var(--text-detail); }
  .notice {
    position: absolute; left: var(--space-12); right: var(--space-12); bottom: var(--space-12); display: flex; gap: var(--space-12); align-items: center; z-index: 5;
    background: var(--smoke); border: 1px solid var(--line2); border-radius: var(--radius-panel); padding: var(--space-8) var(--space-12); box-shadow: var(--shadow-popover);
  }
  .notice span { flex: 1; font: var(--text-detail); }
  .notice button { min-height: 40px; }
</style>
