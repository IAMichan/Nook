<script lang="ts">
  // Chats as on the Mac (`ChatsTab`): the sidebar with the views (All chats, New, Only in Nook, Read), the apps and
  // their accounts, the list of chats with the pinned ones on top and the rest grouped by when they last moved, and the
  // open chat beside it. Every chat app goes through the same list and the same chat (`lib/chats-list.ts`): WhatsApp
  // through its gateway, the others from the shared inbox Nook's chat helper fills (`chatsApi`). The other linked apps (calendar, mail,
  // GitHub, ...) sit under Apps in the sidebar and show what Nook sees in them. With no chat app on, the page says what
  // Chats is, with one click to start (`WSEmptyState`), and the window's sidebar may fold to its icons (`chatsShell`).
  import { listen } from "@tauri-apps/api/event";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../lib/api";
  import { chatsShell } from "../lib/chats-shell.svelte";
  import { chatsApi, connectorEvents, connectorsApi, type ChatSummary, type ConnectorInfo, type Overview, type PullRequestItem, type WhatsAppConversation, type WhatsAppView } from "../lib/connectors";
  import { appName, chatApps, groupTitle, inboxEntry, kindTitle, sections, shown as shownEntries, viewTitle, whatsAppEntry, whatsAppKey, type ChatEntry, type ChatGroup, type ChatListKind, type ChatView } from "../lib/chats-list";
  import { tr } from "../lib/i18n.svelte";
  import { itemId, laneCounts, triage } from "../lib/pulls";
  import { pullRequests } from "../lib/pulls.svelte";
  import { whatsapp } from "../lib/whatsapp.svelte";
  import { chatOptions } from "../lib/chat-options.svelte";
  import DisclosureChevron from "../components/ui/DisclosureChevron.svelte";
  import Ico from "../components/ui/Ico.svelte";
  import IconButton from "../components/ui/IconButton.svelte";
  import ListEmptyNote from "../components/ui/ListEmptyNote.svelte";
  import SearchField from "../components/ui/SearchField.svelte";
  import PullRequestView from "./agents/pulls/PullRequestView.svelte";
  import ChatDetail from "./chats/ChatDetail.svelte";
  import ChatPeople from "./chats/ChatPeople.svelte";
  import ChatRow from "./chats/ChatRow.svelte";
  import ChatsSidebar, { type ChatsMode, type SidebarApp } from "./chats/ChatsSidebar.svelte";
  import { pins, snoozes } from "./chats/chat-actions.svelte";
  import GitHubPanel from "./connectors/GitHubPanel.svelte";

  let { onnook }: { onnook: (nookId: string) => void } = $props();

  const WHATSAPP = "whatsapp";
  const GITHUB = "github";

  let overview = $state<Overview | null>(null);
  let wa = $state<WhatsAppView | null>(null);
  let chats = $state<WhatsAppConversation[]>([]);
  /// Every app's chats in the shared inbox (WhatsApp's too, for their read state).
  let inbox = $state<ChatSummary[]>([]);
  /// The open chat, by the inbox's key.
  let selected = $state<string | null>(null);
  let failed = $state(false);
  let turningOn = $state(false);
  /// The pull request open beside the list while GitHub is chosen, with the account it is listed under.
  let gh = $state<{ account: string; item: PullRequestItem } | null>(null);
  /// Live typing indicators keyed by inbox key (`chat-typing` event from Rust).
  let typingByKey = $state<Record<string, string[]>>({});
  /// Whether the page shows Chats or People (`ChatsMode` on the Mac).
  let mode = $state<ChatsMode>("chats");

  async function load() {
    try {
      const [o, w, i] = await Promise.all([
        connectorsApi.overview(),
        connectorsApi.whatsapp().catch(() => null),
        chatsApi.list().catch(() => []),
        snoozes.refresh(),
      ]);
      overview = o;
      wa = w;
      inbox = i;
      chats = w && w.link.kind === "connected" ? await connectorsApi.whatsappChatList().catch(() => []) : [];
      failed = false;
      reopen();
    } catch {
      failed = true;
    }
  }

  // Reading, muting, hiding or answering a chat changes its unread mark: redraw at once, not at the next poll.
  $effect(() => {
    whatsapp.version;
    load();
  });

  $effect(() => {
    const a = connectorEvents.onChanged(load);
    const b = connectorEvents.onWhatsApp(load);
    const d = connectorEvents.onChats(load);
    const t = listen<{ key: string; typing?: string[] }>("chat-typing", (e) => {
      typingByKey = { ...typingByKey, [e.payload.key]: e.payload.typing ?? [] };
    });
    const timer = setInterval(load, 30_000);
    // Keep relative day groups and expired snooze indicators fresh every minute.
    const clock = setInterval(() => {
      now = new Date();
    }, 60_000);
    return () => {
      a.then((f) => f());
      b.then((f) => f());
      d.then((f) => f());
      t.then((f) => f());
      clearInterval(timer);
      clearInterval(clock);
      chatsShell.folded = false;
    };
  });

  let now = $state(new Date());

  // What the list shows, remembered between visits as on the Mac (`ChatsTab.kept`).
  const KEPT = "chats.kept";
  type Kept = { view: ChatView; app: string | null; account: string | null; kind: ChatListKind; collapsed: ChatGroup[] };
  function loadKept(): Kept {
    const fallback: Kept = { view: "all", app: null, account: null, kind: "chats", collapsed: [] };
    try { return { ...fallback, ...JSON.parse(localStorage.getItem(KEPT) ?? "{}") }; } catch { return fallback; }
  }
  const kept = loadKept();
  let view = $state<ChatView>(kept.view);
  let filter = $state<string | null>(kept.app);
  let account = $state<string | null>(kept.account);
  let kind = $state<ChatListKind>(kept.kind);
  let collapsed = $state<ChatGroup[]>(kept.collapsed);
  let query = $state("");
  $effect(() => {
    const next: Kept = { view, app: filter, account, kind, collapsed };
    try { localStorage.setItem(KEPT, JSON.stringify(next)); } catch { /* The choice lasts until the window closes. */ }
  });

  const domainOf = (id: string) => overview?.services.find((s) => s.id === id)?.domain ?? null;
  // The other linked apps with something to show; WhatsApp is a chat app of its own.
  const others = $derived((overview?.connectors ?? []).filter((c) => c.configured && c.on && c.id !== WHATSAPP));
  const whatsappOn = $derived(!!wa?.settings?.enabled);
  const byKey = $derived(new Map(inbox.map((s) => [s.key, s])));
  const withTyping = (e: ChatEntry): ChatEntry => (e.key in typingByKey ? { ...e, typing: typingByKey[e.key] } : e);
  const all = $derived<ChatEntry[]>([
    ...chats.map((c) => withTyping(whatsAppEntry(c, byKey.get(whatsAppKey(c.id)), wa?.link.kind === "connected"))),
    ...inbox.filter((s) => s.app !== WHATSAPP).map((s) => withTyping(inboxEntry(s))),
  ]);
  /// The chat apps with chats here (or switched on), busiest first after WhatsApp.
  const chatAppIds = $derived([...new Set([...(whatsappOn ? [WHATSAPP] : []), ...all.map((e) => e.app)])]);
  const chatApp = $derived(!filter || chatAppIds.includes(filter));
  /// The chosen app's accounts, while it has chats in more than one: they show under it.
  const accounts = $derived(filter ? [...new Set(all.filter((e) => e.app === filter && e.account).map((e) => e.account!))] : []);
  const shownAccount = $derived(account && accounts.length > 1 && accounts.includes(account) ? account : null);
  const kinds = $derived<ChatListKind[]>((["chats", "status", "channels"] as ChatListKind[]).filter((k) => k === "chats" || all.some((e) => e.listKind === k)));
  const shownKind = $derived(kinds.includes(kind) ? kind : "chats");
  const list = $derived(shownEntries(all, { view, app: chatApp ? filter : null, account: shownAccount, kind: shownKind, query }));
  const groups = $derived(sections(list, now, pins.keys));
  const searching = $derived(!!query.trim());
  const inScope = $derived(all.filter((e) => e.listKind === "chats" && (!filter || !chatApp || e.app === filter) && (!shownAccount || e.account === shownAccount)));
  const counts = $derived({ unread: inScope.filter((e) => e.read === "unread").length, readInNook: inScope.filter((e) => e.read === "readInNook").length });
  const newIn = (pick: (e: ChatEntry) => boolean) => all.filter((e) => e.listKind === "chats" && e.read === "unread" && pick(e)).length;

  // What waits on you in GitHub (reviews asked, CI to fix) counts on its row, not the number of rows in the status.
  const githubCount = $derived.by(() => {
    const counts = laneCounts(triage(pullRequests.accounts));
    return counts.review + counts.fix;
  });
  const apps = $derived<SidebarApp[]>([
    ...chatAppIds.map((id) => ({ id, title: appName(id), domain: chatApps[id]?.domain ?? null, count: newIn((e) => e.app === id) })),
    ...others.map((c) => ({ id: c.id, title: c.title, domain: domainOf(c.id), count: c.id === GITHUB ? githubCount : c.status.items.length })),
  ]);
  // A chosen app that is gone (switched off, unlinked) no longer filters the list.
  $effect(() => {
    if (overview && filter && !apps.some((a) => a.id === filter)) filter = null;
  });

  /// Nothing to show yet: the Mac's empty page instead of the three columns.
  const empty = $derived(!!overview && !all.length && !others.length);
  $effect(() => {
    chatsShell.folded = empty;
  });

  const open = $derived(selected ? all.find((e) => e.key === selected) ?? null : null);
  // A chat you open is read in Nook once it has been on screen a moment, and so is what comes in while it stays open
  // (`readOpenChat`, "Read in Nook when opened"): its badge goes and stays gone after a restart. Its app hears it when you
  // answer or choose Mark as read in the app. The same for every app.
  $effect(() => {
    const e = open;
    if (!e || e.read !== "unread" || !chatOptions.readOnOpen) return;
    const timer = setTimeout(() => {
      if (document.visibilityState === "visible") chatsApi.markRead(e.key, false).then(() => whatsapp.version++).catch(() => {});
    }, 800);
    return () => clearTimeout(timer);
  });

  // The WhatsApp card closed elsewhere (muted, hidden): its chat closes here too.
  $effect(() => {
    if (selected?.startsWith(`${WHATSAPP}#`) && !whatsapp.chat) selected = null;
  });

  // The chat you opened last opens again when you come back, as the Mac's does (`ChatsTab.lastOpened`).
  const LAST = "chats.lastOpened";
  let reopened = false;
  function reopen() {
    if (reopened || selected || gh) return;
    reopened = true;
    let key: string | null = null;
    try { key = localStorage.getItem(LAST); } catch { /* none remembered */ }
    const entry = key ? all.find((e) => e.key === key) : undefined;
    if (entry) openChat(entry);
  }

  // A WhatsApp chat Nook has no messages of yet (it only knows it from the phone) is fetched first, so it opens filled.
  // Every other app's chat reads itself from the inbox (`ChatDetail`).
  async function openChat(e: ChatEntry) {
    gh = null;
    selected = e.key;
    try { localStorage.setItem(LAST, e.key); } catch { /* not remembered */ }
    if (e.app !== WHATSAPP) {
      if (whatsapp.chat) whatsapp.dismiss();
      return;
    }
    const chat = chats.find((c) => c.id === e.id);
    if (chat && !chat.messages.length) await connectorsApi.whatsappCardLoad(e.id).catch(() => {});
    whatsapp.show(e.id);
  }

  // A search hit (or anything else in Nook) opens a chat by its inbox key, also while Chats is already on screen.
  $effect(() => {
    const opened = (e: Event) => {
      const key = (e as CustomEvent<string>).detail;
      const entry = all.find((x) => x.key === key);
      if (entry) {
        mode = "chats";
        filter = null;
        view = "all";
        query = "";
        openChat(entry);
      } else {
        // Not listed yet (the list is still loading): it opens once it is.
        mode = "chats";
        try { localStorage.setItem(LAST, key); } catch { /* not remembered */ }
        reopened = false;
        selected = null;
      }
    };
    window.addEventListener("nook-open-chat", opened);
    // A chat notification's click, from Rust.
    const off = connectorEvents.onOpenChat((key) => opened(new CustomEvent("nook-open-chat", { detail: key })));
    return () => {
      window.removeEventListener("nook-open-chat", opened);
      off.then((f) => f());
    };
  });

  function closeChat() {
    try { localStorage.removeItem(LAST); } catch { /* nothing to forget */ }
    selected = null;
    whatsapp.dismiss();
  }

  function openPull(account: string, item: PullRequestItem) {
    closeChat();
    gh = { account, item };
  }

  function item(url: string | null) {
    if (url) openUrl(url).catch(() => {});
    else settings("connections");
  }

  /// Every chat in the list with something new, read in Nook (`markAllChatsReadInNook`).
  async function markAllRead() {
    await chatsApi.markAllRead(list.filter((e) => e.read === "unread").map((e) => e.key)).catch(() => {});
    whatsapp.version++;
  }

  function settings(section = "chats") {
    try {
      localStorage.setItem("settings.section", section);
    } catch {
      // The window opens on its last section instead.
    }
    api.showMain("settings");
  }

  /// One click starts collecting, as the Mac's Turn on does: WhatsApp is switched on; linking the phone is in Settings.
  async function turnOn() {
    if (!wa) return settings();
    turningOn = true;
    try {
      await connectorsApi.whatsappSave({ ...wa.settings, enabled: true });
      await load();
    } catch {
      settings();
    } finally {
      turningOn = false;
    }
  }

  function toggle(g: ChatGroup) {
    collapsed = collapsed.includes(g) ? collapsed.filter((x) => x !== g) : [...collapsed, g];
  }

  // Escape closes the open chat when nothing else has the key.
  function keydown(e: KeyboardEvent) {
    if (e.key !== "Escape" || e.defaultPrevented || mode !== "chats" || !(selected || gh)) return;
    const target = e.target instanceof Element ? e.target : null;
    if (target?.closest("input, textarea, [contenteditable], dialog, [role='dialog'], [role='menu']")) return;
    if (gh) gh = null;
    else closeChat();
  }

  // In the main window the sidebar's column moves into the window's sidebar, under the tabs, as on the Mac.
  let docked = $state(false);
  function dock(node: HTMLElement) {
    const slot = document.getElementById("sidebar-slot");
    // A narrow window folds the sidebar to icons: the column then stays in the page.
    if (!slot || slot.offsetWidth < 180) return;
    slot.appendChild(node);
    docked = true;
    return { destroy: () => node.remove() };
  }

  const listTitle = $derived([viewTitle(view), filter ? apps.find((a) => a.id === filter)?.title ?? filter : null, shownAccount, shownKind === "chats" ? null : kindTitle(shownKind)].filter(Boolean).join(" · "));
  const otherApp = $derived<ConnectorInfo | null>(filter && !chatApp ? others.find((c) => c.id === filter) ?? null : null);
</script>

<svelte:window onkeydown={keydown} />

<div class="chats" class:undocked={!docked}>
  {#if failed && !overview}
    <ListEmptyNote text={tr("De gekoppelde apps konden niet worden geladen.", "The linked apps could not be loaded.")} />
  {:else if !overview}
    <ListEmptyNote text={tr("Laden…", "Loading…")} />
  {:else if empty}
    <!-- The Mac's empty page (`WSEmptyState`): what Chats is, and one click to start. -->
    <div class="empty-page">
      <span class="empty-icon"><Ico name="inbox" size={30} stroke={1.6} /></span>
      {#if !whatsappOn}
        <strong>{tr("Al je chats op één plek", "All your chats in one place")}</strong>
        <p>{tr("Nook kan je WhatsApp-chats hier verzamelen, naast je Nooks en je agents, zodat je ze leest en beantwoordt zonder van app te wisselen. Alles blijft op deze computer. Telegram, Signal en de andere chatapps volgen. Eén klik en het begint.", "Nook can collect your WhatsApp chats here, next to your Nooks and your agents, so you read and answer them without switching apps. Everything stays on this computer. Telegram, Signal and the other chat apps follow. One click and it starts.")}</p>
        <div class="empty-actions">
          <button class="primary-button" onclick={turnOn} disabled={turningOn}><Ico name="inbox" size={13} stroke={2.4} />{tr("Zet aan", "Turn on")}</button>
          <button class="ghost-button" onclick={() => settings()}><Ico name="settings" size={13} stroke={2.2} />{tr("Instellen", "Set up")}</button>
        </div>
      {:else}
        <strong>{tr("Nog geen chats", "No chats yet")}</strong>
        <p>{wa && wa.link.kind !== "connected" ? wa.statusLine : tr("Nieuwe WhatsApp-berichten verschijnen hier zodra ze binnenkomen.", "New WhatsApp messages show up here as soon as they arrive.")}</p>
        <div class="empty-actions">
          <button class="ghost-button" onclick={() => settings()}><Ico name="settings" size={13} stroke={2.2} />{tr("Instellen", "Set up")}</button>
        </div>
      {/if}
    </div>
  {:else}
    <div class="sidebar-column" use:dock>
      <ChatsSidebar {mode} {view} app={filter} {counts} {apps} accounts={accounts.length > 1 ? accounts.map((a) => ({ name: a, count: newIn((e) => e.app === filter && e.account === a) })) : []} account={shownAccount}
        onmode={(m) => (mode = m)} onview={(v) => { mode = "chats"; view = v; }} onapp={(id) => { mode = "chats"; filter = id; account = null; gh = null; }} onaccount={(a) => { mode = "chats"; account = a; }} onadd={() => settings()} />
    </div>

    {#if mode === "people"}
      <ChatPeople entries={all} {now} onopenchat={(e) => { mode = "chats"; filter = null; view = "all"; query = ""; openChat(e); }} />
    {:else}
    <section class="list" aria-label={listTitle}>
      <!-- The list's title (`PanelListHeader`): the view, and the app when one is chosen, with the one action that fits. -->
      <header class="list-head" data-tauri-drag-region>
        <span class="list-title" data-tauri-drag-region>{listTitle}</span>
        <span class="spacer" data-tauri-drag-region></span>
        {#if chatApp && list.some((e) => e.read === "unread")}
          <IconButton title={tr("Alles gelezen in Nook", "Mark all read in Nook")} onclick={markAllRead}><Ico name="circle-check" size={15} /></IconButton>
        {/if}
      </header>
      {#if chatApp && kinds.length > 1}
        <div class="kinds" role="tablist">
          {#each kinds as k (k)}
            {@const count = all.filter((e) => e.listKind === k && e.read === "unread" && (!filter || e.app === filter)).length}
            <button role="tab" class="kind" class:on={shownKind === k} aria-selected={shownKind === k} onclick={() => (kind = k)}>
              {kindTitle(k)}{#if count}<span class="kind-count">{count}</span>{/if}
            </button>
          {/each}
        </div>
      {/if}
      {#if chatApp}
        <div class="search"><SearchField bind:value={query} placeholder={tr("Zoek in chats", "Search chats")} /></div>
      {/if}

      <div class="rows">
        {#if filter === GITHUB}
          <GitHubPanel active={gh ? `${gh.account} ${itemId(gh.item)}` : null} onopen={openPull} />
        {:else if otherApp}
          {#if otherApp.status.headline}<ListEmptyNote text={otherApp.status.headline} />{/if}
          {#each otherApp.status.items.slice(0, 30) as it (it.id)}
            <button class="item" onclick={() => item(it.url)}>
              <span class="item-dot {it.tone}"></span>
              <span class="item-what">
                <span class="item-title">{it.title}</span>
                {#if it.subtitle}<span class="item-sub">{it.subtitle}</span>{/if}
              </span>
            </button>
          {:else}
            <ListEmptyNote text={otherApp.status.detail || tr("Niets nieuws.", "Nothing new.")} />
          {/each}
        {:else}
          {#each groups as s, i (s.group)}
            {@const isOpen = searching || !collapsed.includes(s.group)}
            <button class="group" class:first={i === 0} aria-expanded={isOpen} disabled={searching} onclick={() => toggle(s.group)}>
              <span>{groupTitle(s.group)}</span>
              <span class="chev" class:shut={!isOpen}><DisclosureChevron open={isOpen} size={9} /></span>
              <span class="spacer"></span>
              {#if !isOpen}<span class="group-count">{s.entries.length}</span>{/if}
            </button>
            {#if isOpen}
              {#each s.entries as e, j (e.id)}
                {#if j > 0}<div class="separator" aria-hidden="true"></div>{/if}
                <ChatRow entry={e} selected={selected === e.key} {now} onselect={() => openChat(e)} onclosed={() => { if (selected === e.key) closeChat(); }} />
              {/each}
            {/if}
          {/each}
          {#if !list.length}
            <div class="list-empty">
              {#if searching}
                <ListEmptyNote text={tr("Geen chats gevonden", "No chats found")} />
              {:else if view !== "all"}
                <ListEmptyNote text={view === "unread" ? tr("Niets nieuw. Je bent helemaal bij.", "Nothing new. You're all caught up.") : view === "readInNook" ? tr("Alles wat je in Nook las, is ook in de apps gelezen.", "Everything you read in Nook is read in its app too.") : tr("Nog geen chats die overal gelezen zijn.", "No chats read everywhere yet.")} />
                <button class="small-ghost" onclick={() => (view = "all")}>{tr("Toon alle chats", "Show all chats")}</button>
              {:else if !whatsappOn}
                <ListEmptyNote text={tr("Zet WhatsApp aan, dan staan je chats hier.", "Turn on WhatsApp and your chats show up here.")} />
                <button class="small-ghost" onclick={turnOn} disabled={turningOn}>{tr("Zet aan", "Turn on")}</button>
              {:else}
                <ListEmptyNote text={wa && wa.link.kind !== "connected" ? wa.statusLine : tr("Nog geen chats", "No chats yet")} />
                <button class="small-ghost" onclick={() => settings()}>{tr("Instellen", "Set up")}</button>
              {/if}
            </div>
          {/if}
        {/if}
      </div>
    </section>

    <section class="detail">
      {#if gh}
        <div class="pr">
          {#key `${gh.account} ${itemId(gh.item)}`}
            <PullRequestView accountId={gh.account} item={gh.item} onback={() => (gh = null)} />
          {/key}
        </div>
      {:else if open}
        {#key open.key}<ChatDetail entry={open} targets={all.filter((e) => e.sends && e.listKind === "chats")} onclose={closeChat} {onnook} onopenchat={(key) => { const next = all.find((x) => x.key === key); if (next) openChat(next); }} />{/key}
      {:else}
        <!-- No chat open (none picked yet, or closed with Escape). -->
        <div class="placeholder" data-tauri-drag-region>
          <span class="placeholder-icon"><Ico name="messages-square" size={30} stroke={1.4} /></span>
          <span class="placeholder-title">{tr("Kies een chat", "Pick a chat")}</span>
          <span class="placeholder-detail">{tr("Open een chat in de lijst. Esc sluit hem weer.", "Open a chat from the list. Escape closes it again.")}</span>
        </div>
      {/if}
    </section>
    {/if}
  {/if}
</div>

<style>
  .chats { height: 100%; min-height: 0; display: flex; }
  /* Docked, the sidebar's column lives in the window's sidebar; else it is the page's first column. */
  .sidebar-column { flex: 1; display: flex; flex-direction: column; min-height: 0; }
  .undocked .sidebar-column { flex: none; height: 100%; width: 184px; padding: var(--space-8) var(--space-6); border-right: 1px solid var(--border); box-sizing: border-box; }

  /* The list (`PanelLayout.chatsList`): 320 wide beside the chat, with a line between them. */
  .list { flex: none; width: 334px; min-height: 0; display: flex; flex-direction: column; gap: var(--space-8); padding: 0 var(--space-4) 0 var(--space-8); border-right: 1px solid var(--border); box-sizing: border-box; }
  /* `PanelListHeader`: 30 high, its title on the window's top row. */
  .list-head { display: flex; align-items: center; gap: var(--space-6); height: 30px; padding: 11px var(--space-4) 0 var(--space-12); flex: none; }
  .list-title { font: var(--text-title); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .spacer { flex: 1; }
  .kinds { display: flex; gap: var(--space-2); padding: var(--space-2); margin: 0 var(--space-4); background: var(--surface); border-radius: var(--radius-control); flex: none; }
  .kind { flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: var(--space-4); height: 26px; padding: 0 var(--space-8); border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text3); font: var(--text-label); }
  .kind:hover:not(:disabled) { background: var(--row-hover); border: 0; color: var(--text2); }
  .kind.on { background: var(--row-selected); color: var(--paper); }
  .kind-count { color: var(--amber); font-variant-numeric: tabular-nums; }
  .search { padding: 0 var(--space-4); flex: none; }
  .search :global(.search) { background: var(--field); border-color: transparent; }
  .rows { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-2); padding-bottom: var(--space-12); }

  /* A group's title (`ChatsGroupHeader`): written as a group's name, the chevron shows under the pointer or when shut. */
  .group { display: flex; align-items: center; gap: var(--space-4); width: 100%; padding: var(--space-12) var(--space-12) var(--space-4); border: 0; background: transparent; color: var(--text3); font: var(--text-label); text-align: left; }
  .group.first { padding-top: var(--space-4); }
  .group:hover:not(:disabled) { background: transparent; border: 0; color: var(--text2); }
  .group:disabled { opacity: 1; }
  .chev { display: inline-flex; opacity: 0; transition: opacity 120ms ease; }
  .group:hover .chev, .chev.shut { opacity: 1; }
  .group-count { font: var(--text-caption); font-variant-numeric: tabular-nums; }
  .separator { height: 1px; margin: var(--space-2) var(--space-12); background: var(--separator); flex: none; }
  .list-empty { display: flex; flex-direction: column; align-items: center; gap: var(--space-6); padding-top: var(--space-16); text-align: center; }
  .small-ghost { height: 26px; padding: 0 var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); font: var(--text-label); }
  .small-ghost:hover:not(:disabled) { background: var(--row-hover); border: 0; color: var(--paper); }

  .item { display: flex; align-items: center; gap: var(--space-8); width: 100%; padding: var(--space-8) var(--space-12); border: 0; border-radius: var(--radius-card); background: transparent; text-align: left; color: inherit; }
  .item:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .item-dot { width: 6px; height: 6px; border-radius: 50%; flex: none; background: var(--text3); }
  .item-dot.good { background: var(--mint); }
  .item-dot.attention { background: var(--amber); }
  .item-dot.bad { background: var(--coral); }
  .item-what { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: var(--space-2); }
  .item-title { font: var(--text-emphasis); line-height: 1.3; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .item-sub { font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .detail { flex: 1; min-width: 0; min-height: 0; padding-left: var(--space-12); padding-right: var(--space-16); }
  .pr { height: 100%; padding: var(--space-12) 0; box-sizing: border-box; }
  .placeholder { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--space-6); text-align: center; }
  .placeholder-icon { color: var(--text-muted); }
  .placeholder-title { font: var(--text-body); color: var(--text2); }
  .placeholder-detail { font: var(--text-detail); color: var(--text3); }

  /* The empty page (`WSEmptyState` with `NookPrimaryButton` and `NookGhostButton`). */
  /* The footer takes the foot of the page here (the folded rail), so the page centers in the room above it. */
  .empty-page { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; padding: 30px 30px calc(var(--space-24) + var(--space-48)); text-align: center; }
  .empty-icon { color: var(--text3); display: inline-flex; margin-bottom: calc(-1 * var(--space-2)); }
  .empty-page strong { font: var(--text-title); color: var(--paper); }
  .empty-page p { margin: 0; max-width: 380px; font: var(--text-body); line-height: 1.2; color: var(--text2); }
  .empty-actions { display: flex; gap: var(--space-6); padding-top: var(--space-4); }
  .primary-button, .ghost-button { display: inline-flex; align-items: center; gap: 7px; height: 38px; padding: 0 var(--space-12); border: 0; border-radius: var(--radius-control); font: var(--text-emphasis); font-weight: 600; white-space: nowrap; }
  .primary-button { padding: 0 14px; background: var(--iris); color: var(--on-iris); }
  .primary-button:hover:not(:disabled) { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); border: 0; }
  .ghost-button { gap: var(--space-6); background: transparent; color: var(--text2); }
  .ghost-button:hover:not(:disabled) { background: var(--graphite); border: 0; color: var(--paper); }
</style>
