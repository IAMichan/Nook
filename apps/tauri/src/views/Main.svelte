<script lang="ts">
  // Het hoofdvenster (en de hele app op Android): Chat met al je Nooks, Agents, Werkruimte en Instellingen.
  import { tick } from "svelte";
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import Chats from "./Chats.svelte";
  import NookList from "../components/NookList.svelte";
  import Orb from "../components/Orb.svelte";
  import Icon from "../components/Icon.svelte";
  import CommandPalette from "../components/CommandPalette.svelte";
  import { conversationMarkdown } from "../lib/conversation-export";
  import { toast } from "../lib/toast.svelte";
  import LazyView from "../components/LazyView.svelte";
  import { parseRoute, reloadRoute, resumeRoute, routeTitles, routeViews, type Route } from "../lib/shell-routes";
  import { shellShortcut } from "../lib/shell-shortcuts";
  import { companion } from "../lib/companion";
  import { onBack, setupMobile } from "../lib/mobile";
  import { gamer } from "../lib/gamer.svelte";
  import { pullRequests } from "../lib/pulls.svelte";
  import { agents } from "../lib/agents.svelte";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import type { Target } from "../lib/inbox";
  import { tr } from "../lib/i18n.svelte";
  import MicButton from "../components/MicButton.svelte";
  import Music from "./services/Music.svelte";

  let route = $state<Route>(resumeRoute());
  let paletteOpen = $state(false);
  let width = $state(window.innerWidth);
  // The sidebar's state is remembered. Below the narrow breakpoint it is an overlay that starts closed.
  const SIDEBAR_KEY = "nook.sidebar.open";
  const storedSidebar = () => { try { return localStorage.getItem(SIDEBAR_KEY) !== "0"; } catch { return true; } };
  let showList = $state(window.innerWidth > 860 ? storedSidebar() : false);
  const android = $derived(nook.info?.capabilities.os === "android");
  // De telefoonindeling: op Android, en in een smal venster op de computer.
  const mobile = $derived(android || width <= 640);
  let companionClient = $state(false);
  // Between the phone and the full layout the sidebar floats over the page instead of taking room from it.
  const narrow = $derived(!mobile && width <= 860);
  const overlay = $derived(narrow && showList && route === "chat");

  $effect(() => {
    if (mobile || narrow) return;
    try { localStorage.setItem(SIDEBAR_KEY, showList ? "1" : "0"); } catch { /* remembering is a convenience */ }
  });

  // The title in the top bar renames the conversation in place: click it, type, Enter keeps and Escape drops.
  let renaming = $state(false);
  let titleDraft = $state("");
  async function commitRename() {
    if (!renaming) return;
    renaming = false;
    const id = nook.activeId;
    const title = titleDraft.trim();
    if (!id || !title || title === nook.active?.title) return;
    try { await api.setNookFlags(id, { title }); await nook.refreshList(); await nook.load(id); }
    catch (e) { toast.error(tr("Kon het gesprek niet hernoemen", "Could not rename conversation"), e); }
  }

  // Gamer Mode's coaching shows up as a toast on any page.
  $effect(() => gamer.start());

  // The pull request list (and the pages you are likely to open) stay current while its page is closed.
  $effect(() => pullRequests.followInBackground());

  $effect(() => {
    companion.info().then((i) => (companionClient = i.client)).catch(() => {});
  });

  // Music: a tab of its own while something plays (as in the bar and on the Mac).
  let playing = $state<NowPlaying | null>(null);
  let playingSince = $state(Date.now());
  $effect(() => {
    services.nowPlaying().then((n) => ((playing = n), (playingSince = Date.now()))).catch(() => {});
    const un = serviceEvents.onNowPlaying((n) => {
      playing = n;
      playingSince = Date.now();
      if (!n && route === "music") route = "chat";
    });
    return () => {
      un.then((f) => f());
    };
  });

  // Android: marges, toetsenbord, terugknop en "Delen met Nook" (een nieuwe vraag in een nieuwe Nook).
  let mobileReady = false;
  $effect(() => {
    if (!android || mobileReady) return;
    mobileReady = true;
    setupMobile(async (text) => {
      route = "chat";
      await nook.newNook();
      showList = false;
      await nook.ask(text);
    });
  });

  // Terug: van een gesprek naar de lijst, van een ander scherm naar de chat.
  $effect(() => onBack(() => {
    if (paletteOpen) return (paletteOpen = false), true;
    if (route === "chat" && mobile && !showList) return (showList = true), true;
    if (route !== "chat") return (route = "chat"), true;
    return false;
  }));

  // "nook:<id>" (from the bar's Open in window) opens that same conversation, so you continue where you were.
  function applyRoute(r: string) {
    if (r.startsWith("nook:")) {
      route = "chat";
      if (mobile) showList = false;
      nook.select(r.slice(5)).catch(() => {});
    } else route = parseRoute(r);
  }

  $effect(() => {
    api.takeRoute().then((r) => r && applyRoute(r));
    const un = events.onNavigate((r) => {
      applyRoute(r);
      api.takeRoute();
    });
    return () => {
      un.then((f) => f());
    };
  });

  // Op de telefoon is de lijst een eigen scherm: een Nook kiezen opent hem.
  let lastActive: string | null = null;
  $effect(() => {
    if (mobile && nook.activeId && lastActive && nook.activeId !== lastActive) showList = false;
    lastActive = nook.activeId;
  });

  const titleOf = (r: Route): string => {
    switch (r) {
      case "music": return tr("Muziek", "Music");
      case "workspace": return tr("Werkruimte", "Workspace");
      case "settings": return tr("Instellingen", "Settings");
      default: return routeTitles[r];
    }
  };
  const routeTitle = $derived(titleOf(route));
  type TabIcon = "chat" | "agents" | "message" | "voice" | "workspace" | "gamepad" | "phone";
  // The Mac's tabs on one bar: Nook, Agents, Chats, and Music while something plays.
  const tabs = $derived<{ route: Route; icon: TabIcon }[]>([
    { route: "chat", icon: "chat" },
    { route: "agents", icon: "agents" },
    { route: "chats", icon: "message" },
    ...(playing || route === "music" ? [{ route: "music" as Route, icon: "voice" as const }] : []),
  ]);
  // Nook's own pages, in the footer: Workspace, Gamer Mode and, on a paired PC, Companion.
  const extras = $derived<{ route: Route; icon: TabIcon }[]>([
    ...(nook.info?.capabilities.terminals ? [{ route: "workspace" as Route, icon: "workspace" as const }] : []),
    { route: "games", icon: "gamepad" },
    ...(companionClient ? [{ route: "companion" as Route, icon: "phone" as const }] : []),
  ]);
  // Ctrl+1 … Ctrl+9 in the order they show: the tabs, then the footer's pages.
  const pages = $derived([...tabs, ...extras]);
  const status = $derived(nook.waiting ? tr("Wacht op je", "Waiting for you") : nook.working ? tr("Bezig", "Working") : nook.info?.brainReady ? tr("Klaar", "Ready") : tr("Stel je brein in", "Set up your brain"));
  // Which footer page the Agents tab shows (pull requests or usage), to light its button.
  const agentsPage = $derived(route === "agents" ? agents.selectedId : null);

  function keys(e: KeyboardEvent) {
    const target = e.target instanceof Element ? e.target : null;
    if (e.key === "Escape" && overlay && !paletteOpen) { showList = false; return; }
    const shortcut = shellShortcut(e, {
      paletteOpen, chat: route === "chat",
      modalOpen: !!document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]'),
      editing: !!target?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], .xterm'),
    });
    if (!shortcut) return;
    // Ctrl+F belongs to the shell inside a terminal.
    if (shortcut === "search" && target?.closest(".xterm")) return;
    const page = shortcut.startsWith("go-") ? pages[Number(shortcut.slice(3)) - 1] : undefined;
    if (shortcut.startsWith("go-") && !page) return;
    e.preventDefault();
    switch (shortcut) {
      case "palette": paletteOpen = !paletteOpen; break;
      case "sidebar": showList = !showList; break;
      case "new":
        route = "chat";
        showList = !mobile;
        nook.newNook();
        break;
      case "settings": route = "settings"; break;
      case "stop": nook.stop(); break;
      case "search":
        // In Settings, Ctrl+F finds a setting (as ⌘F on the Mac).
        if (route === "settings") {
          document.querySelector<HTMLInputElement>(".settings-search input")?.select();
          break;
        }
        route = "chat";
        showList = true;
        tick().then(() => document.querySelector<HTMLInputElement>('.list input[aria-label="Search conversations"]')?.select());
        break;
      default:
        if (page) navigate(page.route);
    }
  }

  function navigate(next: Route) {
    route = next;
    if (next === "chat" && mobile) showList = false;
  }

  /// Opens a page of the Agents tab: pull requests or usage (the footer's buttons, as on the Mac).
  function openAgentsPage(page: "pulls" | "usage") {
    agents.select(page);
    navigate("agents");
  }

  /// Opens what the empty chat's rows and cards point at.
  async function openTarget(target: Target) {
    try {
      switch (target.kind) {
        case "route": return navigate(target.route);
        case "settings":
          try { localStorage.setItem("settings.section", target.section); } catch { /* opens on the last page instead */ }
          return navigate("settings");
        case "workspace":
          if (target.page === "usage" || !nook.info?.capabilities.terminals) return openAgentsPage(target.page === "usage" ? "usage" : "pulls");
          try { localStorage.setItem("ws.page", target.page); } catch { /* opens on the last page instead */ }
          return navigate("workspace");
        case "agents":
          agents.select(target.select);
          return navigate("agents");
        case "nook":
          navigate("chat");
          return await nook.select(target.id);
        case "newNook":
          navigate("chat");
          await nook.newNook();
          if (target.ask) await nook.ask(target.ask);
          return;
      }
    } catch (e) {
      nook.error = String(e);
    }
  }

  async function copyConversation() {
    if (!nook.active?.messages.length) return;
    try {
      await navigator.clipboard.writeText(conversationMarkdown(nook.active, nook.streaming));
      toast.success(tr("Gesprek gekopieerd", "Conversation copied"), tr("Tekst gekopieerd als Markdown.", "Text copied as Markdown."));
    } catch (e) { toast.error(tr("Kon het gesprek niet kopiëren", "Could not copy conversation"), e); }
  }
</script>

<svelte:window onkeydown={keys} bind:innerWidth={width} />

<div class="main" class:mobile class:overlay>
  <nav class="rail" aria-label={tr("Hoofdnavigatie", "Main navigation")}>
    <div class="head">
      <Orb size={22} movable mood={nook.waiting ? "waiting" : nook.working ? "working" : "idle"} />
      <span class="spacer"></span>
      <button class="ghost icon-button" onclick={() => (paletteOpen = true)} title={tr("Zoek overal (Ctrl+K)", "Search everything (Ctrl+K)")} aria-label={tr("Zoek overal", "Search everything")}><Icon name="search" size={16} /></button>
      <span class="talk"><MicButton /></span>
    </div>
    <div class="tabbar" role="tablist">
      {#each tabs as tab, i (tab.route)}
        <button role="tab" class="tab" class:on={route === tab.route} aria-selected={route === tab.route} aria-current={route === tab.route ? "page" : undefined} aria-label={titleOf(tab.route)}
          onclick={() => { if (tab.route === "chat" && mobile && route === "chat") showList = !showList; navigate(tab.route); }} title={i < 9 ? `${titleOf(tab.route)} (Ctrl+${i + 1})` : titleOf(tab.route)}>
          <Icon name={tab.icon} size={16} /><span>{titleOf(tab.route)}</span>
        </button>
      {/each}
      {#if mobile}
        {#each extras as tab (tab.route)}
          <button role="tab" class="tab" class:on={route === tab.route} aria-selected={route === tab.route} onclick={() => navigate(tab.route)} title={titleOf(tab.route)}><Icon name={tab.icon} /><span>{titleOf(tab.route)}</span></button>
        {/each}
        <button role="tab" class="tab" class:on={route === "settings"} aria-selected={route === "settings"} onclick={() => (route = "settings")} title={tr("Instellingen", "Settings")}><Icon name="settings" /><span>{tr("Instellingen", "Settings")}</span></button>
      {/if}
    </div>
    {#if !mobile}
      <div class="rule"></div>
      <div class="side-list" id="sidebar-slot" role="presentation" onclick={(e) => {
          const t = e.target as HTMLElement;
          if (overlay && t.closest(".item") && !t.closest(".actions") && !t.closest(".menu-trigger")) showList = false;
        }}>
        {#if route === "chat" && showList}<NookList />{/if}
      </div>
      <div class="footer">
        <button class="ghost icon-button" class:on={route === "settings"} aria-current={route === "settings" ? "page" : undefined} onclick={() => navigate("settings")} title={tr("Instellingen (Ctrl+,)", "Settings (Ctrl+,)")} aria-label={tr("Instellingen", "Settings")}><Icon name="settings" size={16} /></button>
        <button class="ghost icon-button" class:on={agentsPage === "pulls"} onclick={() => openAgentsPage("pulls")} title="Pull requests" aria-label="Pull requests"><Icon name="pull" size={16} /></button>
        <button class="ghost icon-button" class:on={agentsPage === "usage"} onclick={() => openAgentsPage("usage")} title={tr("Gebruik", "Usage")} aria-label={tr("Gebruik", "Usage")}><Icon name="chart" size={16} /></button>
        {#if extras.length}<span class="sep" aria-hidden="true"></span>{/if}
        {#each extras as page, i (page.route)}
          <button class="ghost icon-button" class:on={route === page.route} aria-current={route === page.route ? "page" : undefined} onclick={() => navigate(page.route)}
            title={tabs.length + i < 9 ? `${titleOf(page.route)} (Ctrl+${tabs.length + i + 1})` : titleOf(page.route)} aria-label={titleOf(page.route)}><Icon name={page.icon} size={16} /></button>
        {/each}
        <span class="spacer"></span>
        <span class="status" title={status} role="status" aria-label={status}><span class="dot" class:waiting={nook.waiting > 0} class:working={nook.working > 0} class:unread={!nook.waiting && !nook.working && !!nook.info?.brainReady}></span></span>
      </div>
    {/if}
  </nav>
  <section class="content" aria-label={routeTitle}>
    {#if route === "chat"}
      <div class="chatlayout" class:nolist={!mobile || !showList}>
        {#if mobile && showList}
          <div class="listwrap" role="presentation" onclick={(e) => {
            const t = e.target as HTMLElement;
            if (t.closest(".item") && !t.closest(".menu") && !t.closest(".menu-trigger")) showList = false;
          }}>
            <NookList />
          </div>
        {/if}
        <div class="chatpane">
          <header class="title">
            <button class="ghost icon-button" onclick={() => (showList = !showList)} title={showList ? tr("Verberg gesprekken", "Hide conversations") : tr("Toon gesprekken", "Show conversations")} aria-label={mobile ? tr("Terug naar gesprekken", "Back to conversations") : tr("Gesprekken tonen of verbergen", "Toggle conversations")} aria-expanded={showList}><Icon name={mobile ? "back" : "sidebar"} size={16} /></button>
            {#if renaming}
              <!-- svelte-ignore a11y_autofocus -->
              <input class="rename" aria-label={tr("Titel van het gesprek", "Conversation title")} autofocus bind:value={titleDraft} onblur={commitRename}
                onkeydown={(e) => { if (e.key === "Enter") commitRename(); else if (e.key === "Escape") { e.stopPropagation(); renaming = false; } }} />
            {:else if nook.active}
              <button class="name editable" title={tr("Hernoemen", "Rename")} onclick={() => { titleDraft = nook.active?.title ?? ""; renaming = true; }}>{nook.active.title}</button>
            {:else}
              <span class="name">{tr("Nieuwe Nook", "New Nook")}</span>
            {/if}
            <span class="spacer"></span>
            <button class="ghost icon-button" disabled={!nook.active?.messages.length} onclick={copyConversation} title={tr("Kopieer gesprek als Markdown", "Copy conversation as Markdown")} aria-label={tr("Kopieer gesprek als Markdown", "Copy conversation as Markdown")}><Icon name="copy" size={16} /></button>
            <button class="ghost icon-button" onclick={() => { nook.newNook(); if (mobile) showList = false; }} title={tr("Nieuwe Nook (Ctrl+N)", "New Nook (Ctrl+N)")} aria-label={tr("Nieuwe Nook", "New Nook")}><Icon name="plus" size={16} /></button>
          </header>
          <Chat onopen={openTarget} />
        </div>
      </div>
    {:else if route === "chats"}
      <header class="title page-title"><span class="name">{routeTitle}</span></header>
      <div class="route-body"><Chats onnook={(id) => { nook.select(id); route = "chat"; }} /></div>
    {:else if route === "music"}
      <header class="title page-title"><span class="name">{routeTitle}</span></header>
      <div class="route-body music-body">
        {#if playing}<Music info={playing} since={playingSince} />{:else}<p class="faint quiet">{tr("Er speelt nu niets.", "Nothing is playing right now.")}</p>{/if}
      </div>
    {:else}
      {#if route !== "agents" && route !== "settings"}<header class="title page-title"><span class="name">{routeTitle}</span></header>{/if}
      <div class="route-body">
        {#key route}<LazyView load={routeViews[route]!} label={routeTitle} onretry={() => reloadRoute(route)} />{/key}
      </div>
    {/if}
  </section>
</div>

{#if paletteOpen}<CommandPalette onclose={() => (paletteOpen = false)} onnavigate={navigate} companionEnabled={companionClient} />{/if}

<style>
  /* The main window as on the Mac: one sidebar (search, tab bar, the tab's list, footer) beside the content. */
  .main { display: grid; grid-template-columns: 264px minmax(0, 1fr); height: 100dvh; overflow: hidden; background: var(--canvas); }
  .rail { background: var(--sidebar); border-right: 1px solid var(--border); display: flex; flex-direction: column; min-height: 0; padding: 0 8px 8px; }
  .head { display: flex; align-items: center; gap: 2px; height: 52px; padding: 0 4px; flex: none; }
  .talk { display: contents; }
  .talk :global(.mic) { width: 28px; height: 28px; border-radius: var(--radius-control); color: var(--text2); }
  .talk :global(.mic svg) { width: 16px; height: 16px; }
  .tabbar { display: flex; gap: 2px; padding: 2px; min-height: 34px; background: var(--surface); border-radius: var(--radius-card); flex: none; }
  .tab { display: flex; align-items: center; justify-content: center; gap: 6px; flex: 0 0 auto; min-width: 28px; height: 30px; padding: 0; background: transparent; border: 0; border-radius: var(--radius-control); color: var(--text3); font: var(--text-control); }
  .tab:not(.on) { flex: 1 1 0; }
  .tab span { display: none; }
  .tab.on { padding: 0 10px; background: var(--row-selected); color: var(--paper); }
  .tab.on span { display: inline; }
  .tab:hover:not(.on) { color: var(--text2); background: var(--row-hover); }
  .rule { height: 1px; background: var(--hairline); margin: 12px 0 4px; flex: none; }
  .side-list { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .side-list :global(.list) { flex: 1; background: transparent; border-right: 0; }
  .footer { display: flex; align-items: center; gap: 2px; padding: 6px 0 0; flex: none; border-top: 1px solid var(--hairline); margin-top: 4px; }
  .footer .sep { width: 1px; height: 16px; margin: 0 4px; background: var(--line2); flex: none; }
  .status { display: grid; place-items: center; width: 28px; height: 28px; flex: none; cursor: default; }
  .status .dot { background-color: var(--text3); }
  .status .dot.waiting { background-color: var(--amber); }
  .status .dot.working { background-color: var(--paper); }
  .status .dot.unread { background-color: var(--mint); }
  .spacer { flex: 1; }
  .icon-button { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; flex-shrink: 0; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .icon-button:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
  .icon-button.on { background: var(--row-selected); color: var(--paper); }
  .music-body { overflow-y: auto; }
  .quiet { padding: 24px; text-align: center; }
  .content { min-width: 0; min-height: 0; height: 100%; overflow: hidden; display: flex; flex-direction: column; background: var(--canvas); }
  .chatlayout { display: grid; grid-template-columns: minmax(0, 1fr); height: 100%; }
  .chatpane { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap :global(.list) { flex: 1; }
  .title { min-height: 52px; padding: 0 16px; display: flex; align-items: center; gap: 8px; min-width: 0; flex-shrink: 0; }
  .title .name.editable { background: transparent; border: 0; padding: 4px 8px; margin-left: -8px; border-radius: var(--radius-control); color: var(--paper); text-align: left; min-width: 0; }
  .title .name.editable:hover { background: var(--row-hover); }
  .rename { min-width: 0; flex: 0 1 360px; font: var(--text-title); padding: 4px 8px; margin-left: -8px; }
  .title .name { font: var(--text-title); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .page-title { border-bottom: 1px solid var(--border); }
  .route-body { flex: 1; min-height: 0; overflow: hidden; }
  .chatpane :global(.chat) { flex: 1; min-height: 0; }
  @media (min-width: 641px) and (max-width: 860px) {
    .main { grid-template-columns: 56px minmax(0, 1fr); }
    .rail { padding: 0 6px 8px; }
    .head :global(.orb), .head .spacer, .talk { display: none; }
    .footer { flex-direction: column; border-top: 0; }
    .footer .sep { width: 16px; height: 1px; margin: 4px 0; }
    .tabbar { flex-direction: column; background: transparent; }
    .tab, .tab.on, .tab:not(.on) { flex: none; width: 36px; height: 36px; padding: 0; }
    .tab.on span { display: none; }
    .side-list { display: none; }
    /* The sidebar as an overlay beside the icon rail, over a soft scrim. */
    .main.overlay::after { content: ""; position: fixed; inset: 0 0 0 56px; background: rgb(0 0 0 / 0.35); z-index: 19; animation: fade 160ms ease-out; }
    .main.overlay .side-list { display: flex; position: fixed; z-index: 20; top: 0; bottom: 0; left: 56px; width: 280px; padding: 8px; background: var(--sidebar); border-right: 1px solid var(--border); box-shadow: 0 8px 32px rgb(0 0 0 / 0.28); animation: slide 180ms ease-out; }
  }
  @keyframes fade { from { opacity: 0; } }
  @keyframes slide { from { transform: translateX(-12px); opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .main.overlay::after, .main.overlay .side-list { animation: none; } }
  .main.mobile { grid-template-columns: minmax(0, 1fr); grid-template-rows: 1fr auto; padding: var(--safe-top) var(--safe-right) 0 var(--safe-left); }
  .main.mobile .rail { flex-direction: row; justify-content: space-around; align-items: center; padding: 4px 8px calc(4px + var(--safe-bottom)); order: 2; gap: 0; border-top: 1px solid var(--border); border-right: 0; }
  .main.mobile .head { display: none; }
  .main.mobile .tabbar { flex: 1; background: transparent; justify-content: space-around; }
  .main.mobile .tab, .main.mobile .tab:not(.on), .main.mobile .tab.on { flex: 1; flex-direction: column; max-width: 96px; min-height: 54px; gap: 4px; padding: 7px 4px; background: transparent; }
  .main.mobile .tab span, .main.mobile .tab.on span { display: inline; font-size: 10px; }
  .main.mobile .tab.on { color: var(--paper); }
  .main.mobile .chatlayout:not(.nolist) .chatpane { display: none; }
  .main.mobile .chatlayout:not(.nolist) :global(.list) { border-right: none; }
  .main.mobile .title { min-height: 56px; padding: 8px 12px; }
  :global(html.keyboard-open) .main.mobile { padding-bottom: var(--keyboard); }
  :global(html.keyboard-open) .main.mobile .rail { display: none; }
</style>
