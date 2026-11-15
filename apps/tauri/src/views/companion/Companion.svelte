<script lang="ts">
  // The phone side of the companion, laid out as Nook Companion on the iPhone (`RootView`): the computer's three tabs
  // along the bottom (Nook, Agents and Chats, each with what waits there and keeping where it was), Nook's orb for the
  // computer's menu and the gear for Settings in every tab's header, and a session, a chat with Nook or a chat pushed on
  // its tab. Only what the computer lists (`features`) and allows this phone (`scopes`) shows. On Android, a paired phone
  // opens straight into this (`standalone`); Nook on the phone itself is a tap away in Settings.
  import { untrack } from "svelte";
  import {
    companion, has, may, needingYou, tabsFor, unreadChats, Feature,
    parseNotificationAction, routeWords, type NotificationAction, type ChatDigest, type ClientView, type CompanionTab, type InboxChatDigest, type SessionDigest,
  } from "../../lib/companion";
  import { onBack } from "../../lib/mobile";
  import { tr } from "../../lib/i18n.svelte";
  import { setLocal, shell } from "../../lib/companion-shell.svelte";
  import "./ui/phone.css";
  import Pairing from "./Pairing.svelte";
  import HomeTab from "./HomeTab.svelte";
  import AgentsTab from "./AgentsTab.svelte";
  import ChatsTab from "./ChatsTab.svelte";
  import SessionDetail from "./SessionDetail.svelte";
  import NewSession from "./NewSession.svelte";
  import NookChat from "./NookChat.svelte";
  import InboxChat from "./InboxChat.svelte";
  import SettingsSheet from "./SettingsSheet.svelte";
  import ShareSheet from "./ShareSheet.svelte";
  import TabBar from "./ui/TabBar.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import Sheet from "./ui/Sheet.svelte";
  import { parsePromptLink, type PromptLink } from "../../lib/prompt-link";
  import { looksLikePairingLink } from "../../lib/companion";

  let { standalone = false }: { standalone?: boolean } = $props();

  type Screen = { kind: "session"; id: string; digest?: SessionDigest } | { kind: "nook"; id: string | null; ask?: string } | { kind: "chat"; id: string };

  let view = $state<ClientView | null>(null);
  let tab = $state<CompanionTab>("home");
  // Each tab keeps where it was.
  let screens = $state<Record<CompanionTab, Screen | null>>({ home: null, agents: null, chats: null });
  let sheet = $state<null | "settings" | { kind: "new"; task?: string; link?: PromptLink }>(null);
  let macMenu = $state<DOMRect | null>(null);
  // Pairing another computer shows the pairing screen; the paired ones stay.
  let adding = $state(false);
  let inbox = $state<InboxChatDigest[]>([]);
  let inboxMessage = $state<string | undefined>(undefined);
  let conversations = $state<ChatDigest[]>([]);

  $effect(() => {
    companion.client().then((v) => (view = v));
    companion.refresh().then((v) => (view = v));
    const un = companion.onClient((v) => (view = { ...v, deviceName: view?.deviceName }));
    // Live updates of the lists the tabs count: the Chats tab's inbox and Nook's conversations.
    const live = companion.onLive((r) => {
      if (r.inbox) inbox = r.inbox;
      if (r.conversations) conversations = r.conversations;
    });
    const visible = () => companion.visible(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", visible);
    visible();
    return () => {
      un.then((f) => f());
      live.then((f) => f());
      document.removeEventListener("visibilitychange", visible);
    };
  });

  const paired = $derived(!!view && (view.phase === "connected" || view.phase === "offline"));
  $effect(() => {
    if (view) shell.paired = paired;
  });
  const tabs = $derived(tabsFor(view));
  const showInbox = $derived(has(view, Feature.inbox) && may(view, "chats"));
  const showNook = $derived(has(view, Feature.chat) && may(view, "nookChat"));
  const connected = $derived(view?.phase === "connected");

  // A tab the computer stopped allowing falls back to Agents.
  $effect(() => {
    if (view && !tabs.includes(tab)) tab = "agents";
  });

  // The inbox and Nook's conversations, for the counts on the tabs: on connecting and every 20 seconds unless they follow live.
  async function loadLists() {
    if (!connected) return;
    if (showInbox) {
      const r = await companion.call({ op: "inbox" });
      if (r.response?.inbox) inbox = r.response.inbox;
      inboxMessage = r.response?.message;
    }
    if (showNook) {
      const r = await companion.call({ op: "chats" });
      if (r.response?.conversations) conversations = r.response.conversations;
    }
  }
  $effect(() => {
    if (!connected || (!showInbox && !showNook)) return;
    untrack(loadLists);
    const timer = setInterval(() => document.visibilityState === "visible" && !has(view, Feature.liveChats) && loadLists(), 20_000);
    return () => clearInterval(timer);
  });

  // A nook:// link: a pairing code pairs (when nothing is paired yet), a prompt link opens New session filled in. It
  // never starts by itself.
  $effect(() => {
    const url = shell.link;
    if (!url || !view) return;
    if (looksLikePairingLink(url)) {
      shell.link = null;
      if (!paired) untrack(() => companion.pair(url, view?.deviceName ?? "").then(took));
      return;
    }
    const link = parsePromptLink(url);
    shell.link = null;
    if (!link) return void took({ ...view, notice: tr("Deze link kan Nook niet openen.", "Nook cannot open this link.") });
    if (paired) untrack(() => (sheet = { kind: "new", task: link.text, link }));
  });

  // Push notifications (Android, `NookPush.kt`): the notification service gets each paired computer's push key, and
  // every computer gets this phone's token. Both again when the pairings or the token change.
  const macKey = $derived((view?.macs ?? []).map((m) => m.id).join(","));
  $effect(() => {
    void macKey;
    const bridge = window.NookAndroid;
    if (!bridge?.setPushKeys || !paired) return;
    untrack(async () => {
      bridge.setPushKeys?.(JSON.stringify(await companion.pushKeys()));
      const token = bridge.pushToken?.();
      if (token) await companion.registerPush(token);
    });
  });
  $effect(() => {
    const changed = async () => {
      const token = window.NookAndroid?.pushToken?.();
      if (token) await companion.registerPush(token);
    };
    window.addEventListener("nook-push-token", changed);
    return () => window.removeEventListener("nook-push-token", changed);
  });

  // A tap on a notification, or one of its buttons: that computer becomes active, then the action runs and its session opens.
  async function onNotification(a: NotificationAction) {
    if (view?.macs?.some((m) => m.id === a.mac && !m.active)) await switchTo(a.mac);
    if (a.action === "allow" || a.action === "deny") {
      if (a.item) took(await companion.decide(a.session, a.item, a.action === "allow"));
    } else if (a.action === "reply" && a.text?.trim()) {
      const r = await companion.call({ op: "send", session: a.session, text: a.text.trim() });
      took(r.view);
    }
    open("agents", { kind: "session", id: a.session });
  }
  $effect(() => {
    const take = () => {
      const a = parseNotificationAction(window.NookAndroid?.takeNotification?.());
      if (a && view && paired) untrack(() => onNotification(a));
    };
    if (view && paired) take();
    window.addEventListener("nook-notification", take);
    return () => window.removeEventListener("nook-notification", take);
  });

  // Text another app shared with Nook waits here until you say where it goes.
  const shared = $derived(shell.shared);

  // The back button: a menu, a sheet, then what is open on the tab.
  $effect(() => onBack(() => {
    if (macMenu) return (macMenu = null), true;
    if (screens[tab]) return (screens[tab] = null), true;
    return false;
  }));

  async function act(f: () => Promise<ClientView>) {
    took(await f());
  }
  function took(v: ClientView) {
    view = { ...v, deviceName: view?.deviceName };
  }

  // A notice the computer sent shows as the iPhone's alert, with OK.
  function clearNotice() {
    companion.clearNotice();
    if (view) view.notice = null;
  }

  /** Opens Nook's update panel on the Mac; installing stays a click there. */
  async function requestUpdate() {
    const r = await companion.call({ op: "requestUpdate" });
    if (!r.response) return took(r.view);
    const said = r.response.message === "available" ? tr("De update staat klaar op je Mac.", "The update is waiting on your Mac.")
      : r.response.message === "none" ? tr("Nook op je Mac is bijgewerkt.", "Nook on your Mac is up to date.")
      : tr("Je Mac kan nu niet naar updates kijken.", "Your Mac cannot look for updates right now.");
    took({ ...r.view, notice: said });
  }

  function open(where: CompanionTab, screen: Screen) {
    tab = where;
    screens[where] = screen;
  }

  const counts = $derived<Record<CompanionTab, number>>({
    home: conversations.filter((c) => c.waiting).length,
    agents: needingYou(view?.sessions ?? []),
    chats: unreadChats(inbox),
  });

  const macSections = $derived.by<MenuItem[][]>(() => {
    if (!view) return [];
    const route = view.phase === "connected" ? routeWords(view.route) : null;
    const macs = view.macs ?? [];
    return [
      [
        ...(macs.length > 1
          ? macs.map((m) => ({ label: m.name, icon: m.active ? "check" : "laptop", onselect: m.active ? undefined : () => switchTo(m.id) }))
          : [{ label: view.macName || tr("Je Mac", "Your Mac"), icon: "laptop" }]),
        ...(route ? [{ label: route.text, icon: route.icon }] : []),
        { label: tr("Controleer de verbinding", "Check the connection"), icon: "stethoscope", onselect: () => (sheet = "settings") },
      ],
      has(view, Feature.requestUpdate) ? [{ label: tr("Toon de update op je Mac", "Show the update on your Mac"), icon: "circle-arrow-down", onselect: requestUpdate }] : [],
      [
        { label: tr("Koppel nog een Mac", "Pair another Mac"), icon: "plus", onselect: () => (adding = true) },
        { label: tr("Ontkoppel van deze Mac", "Unpair from this Mac"), destructive: true, onselect: () => act(async () => companion.unpair()) },
      ],
    ];
  });

  /** Makes another paired computer active; its tabs start where they were. */
  async function switchTo(id: string) {
    screens = { home: null, agents: null, chats: null };
    inbox = [];
    conversations = [];
    took(await companion.switchTo(id));
    took(await companion.refresh());
    loadLists();
  }
</script>

<div class="companion phone" class:standalone>
  {#if !view}
    <div class="launch"></div>
  {:else if !paired || adding}
    <Pairing {view} adding={paired} oncancel={() => (adding = false)} onchange={(v) => { view = v; if (adding && v.phase === "connected") { adding = false; screens = { home: null, agents: null, chats: null }; loadLists(); } }} />
  {:else}
    <div class="page">
      {#if tab === "agents" && screens.agents?.kind === "session"}
        <SessionDetail {view} id={screens.agents.id} fallback={screens.agents.digest} onback={() => (screens.agents = null)} {act} {took} />
      {:else if tab === "home" && screens.home?.kind === "nook"}
        <NookChat {view} id={screens.home.id} ask={screens.home.ask} onback={() => { screens.home = null; loadLists(); }} {took} />
      {:else if tab === "chats" && screens.chats?.kind === "chat"}
        {@const id = screens.chats.id}
        <InboxChat {view} {id} chat={inbox.find((c) => c.id === id) ?? null} onback={() => { screens.chats = null; loadLists(); }} {took} />
      {:else if tab === "home"}
        <HomeTab {view} {inbox} {conversations} onorb={(r) => (macMenu = r)} ongear={() => (sheet = "settings")}
          onsession={(id) => open("agents", { kind: "session", id })}
          onchat={(id) => open("chats", { kind: "chat", id })}
          onnook={(id, ask) => open("home", { kind: "nook", id, ask })}
          ontab={(t) => (tab = t)} />
      {:else if tab === "chats"}
        <ChatsTab {view} {inbox} message={inboxMessage} onorb={(r) => (macMenu = r)} ongear={() => (sheet = "settings")} onopen={(id) => open("chats", { kind: "chat", id })} {took} onrefresh={loadLists} />
      {:else}
        <AgentsTab {view} {act} {took} onelsewhere={async (mac, id, digest) => { await switchTo(mac); open("agents", { kind: "session", id, digest }); }} onorb={(r) => (macMenu = r)} ongear={() => (sheet = "settings")}
          onopen={(id, digest) => open("agents", { kind: "session", id, digest })} onnew={() => (sheet = { kind: "new" })} />
      {/if}
    </div>
    {#if tabs.length > 1}
      <div class="tabbar"><TabBar {tabs} {tab} {counts} onpick={(t) => { if (t === tab) screens[t] = null; tab = t; }} /></div>
    {/if}
  {/if}

  {#if sheet === "settings" && view}
    <Sheet onclose={() => (sheet = null)}>
      <SettingsSheet {view} {took} onswitch={(id) => { sheet = null; switchTo(id); }} onadd={() => { sheet = null; adding = true; }} onclose={() => (sheet = null)} onlocal={standalone ? () => { sheet = null; setLocal(true); } : undefined} />
    </Sheet>
  {:else if sheet && typeof sheet === "object" && view}
    <Sheet onclose={() => (sheet = null)}>
      <NewSession {view} task={sheet.task} link={sheet.link} onback={() => (sheet = null)} {took} onstarted={(id) => { sheet = null; if (id) open("agents", { kind: "session", id }); }} />
    </Sheet>
  {/if}

  {#if shared && view && paired}
    <Sheet onclose={() => (shell.shared = null)}>
      <ShareSheet {view} text={shared} onclose={() => (shell.shared = null)}
        onnew={(task) => { shell.shared = null; sheet = { kind: "new", task }; }}
        onnook={(text) => { shell.shared = null; open("home", { kind: "nook", id: null, ask: text }); }}
        onsession={(id) => { shell.shared = null; open("agents", { kind: "session", id }); }} {took} />
    </Sheet>
  {/if}

  {#if macMenu}<Menu sections={macSections} anchor={macMenu} onclose={() => (macMenu = null)} />{/if}

  {#if view?.notice}
    <div class="alert-scrim">
      <div class="alert" role="alertdialog">
        <p>{view.notice}</p>
        <button onclick={clearNotice}>OK</button>
      </div>
    </div>
  {/if}
</div>

<style>
  .companion { height: 100%; display: flex; flex-direction: column; min-height: 0; position: relative; }
  .launch { flex: 1; background: var(--canvas); }
  .page { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  :global(html.keyboard-open) .tabbar { display: none; }
  .alert-scrim { position: fixed; inset: 0; z-index: 60; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; padding: 24px; }
  .alert { width: 270px; background: rgba(37, 37, 37, 0.96); backdrop-filter: blur(30px); border-radius: 14px; overflow: hidden; text-align: center; }
  .alert p { margin: 0; padding: 20px 16px; font: var(--pt-control); color: var(--paper); }
  .alert button { width: 100%; height: 44px; border-top: 0.5px solid rgba(255, 255, 255, 0.12) !important; color: var(--blue) !important; font: 600 17px var(--font) !important; }
</style>
