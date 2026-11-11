<script lang="ts">
  // Het hoofdvenster (en de hele app op Android): Chat met al je Nooks, Agents, Werkruimte en Instellingen.
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

  let route = $state<Route>(resumeRoute());
  let showList = $state(true);
  let paletteOpen = $state(false);
  let width = $state(window.innerWidth);
  const android = $derived(nook.info?.capabilities.os === "android");
  // De telefoonindeling: op Android, en in een smal venster op de computer.
  const mobile = $derived(android || width <= 640);
  let companionClient = $state(false);

  // Gamer Mode's coaching shows up as a toast on any page.
  $effect(() => gamer.start());

  // The pull request list (and the pages you are likely to open) stay current while its page is closed.
  $effect(() => pullRequests.followInBackground());

  $effect(() => {
    companion.info().then((i) => (companionClient = i.client)).catch(() => {});
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

  $effect(() => {
    api.takeRoute().then((r) => r && (route = parseRoute(r)));
    const un = events.onNavigate((r) => {
      route = parseRoute(r);
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

  const routeTitle = $derived(routeTitles[route]);
  // The Mac's tabs (Nook, Agents, Chats), then Nook's own: Workspace, Gamer Mode and, on a paired PC, Companion.
  const tabs = $derived([
    { route: "chat" as Route, title: "Nook", icon: "chat" as const },
    { route: "agents" as Route, title: "Agents", icon: "agents" as const },
    { route: "chats" as Route, title: "Chats", icon: "message" as const },
    ...(nook.info?.capabilities.terminals ? [{ route: "workspace" as Route, title: "Workspace", icon: "workspace" as const }] : []),
    { route: "games" as Route, title: "Gamer Mode", icon: "gamepad" as const },
    ...(companionClient ? [{ route: "companion" as Route, title: "Companion", icon: "phone" as const }] : []),
  ]);
  const status = $derived(nook.waiting ? "Waiting for you" : nook.working ? "Working" : nook.info?.brainReady ? "Ready" : "Set up your brain");

  function keys(e: KeyboardEvent) {
    const target = e.target instanceof Element ? e.target : null;
    const shortcut = shellShortcut(e, {
      paletteOpen, chat: route === "chat",
      modalOpen: !!document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]'),
      editing: !!target?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], .xterm'),
    });
    if (!shortcut) return;
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
    }
  }

  function navigate(next: Route) {
    route = next;
    if (next === "chat" && mobile) showList = false;
  }

  async function copyConversation() {
    if (!nook.active?.messages.length) return;
    try {
      await navigator.clipboard.writeText(conversationMarkdown(nook.active, nook.streaming));
      toast.success("Conversation copied", "Text copied as Markdown.");
    } catch (e) { toast.error("Could not copy conversation", e); }
  }
</script>

<svelte:window onkeydown={keys} bind:innerWidth={width} />

<div class="main" class:mobile>
  <nav class="rail" aria-label="Main navigation">
    <div class="head">
      <Orb size={22} movable mood={nook.waiting ? "waiting" : nook.working ? "working" : "idle"} />
      <span class="spacer"></span>
      <button class="ghost icon-button" onclick={() => (paletteOpen = true)} title="Search everything (Ctrl+K)" aria-label="Search everything"><Icon name="search" /></button>
    </div>
    <div class="tabbar" role="tablist">
      {#each tabs as tab (tab.route)}
        <button role="tab" class="tab" class:on={route === tab.route} aria-selected={route === tab.route} aria-current={route === tab.route ? "page" : undefined}
          onclick={() => { if (tab.route === "chat" && mobile && route === "chat") showList = !showList; navigate(tab.route); }} title={tab.title}>
          <Icon name={tab.icon} /><span>{tab.title}</span>
        </button>
      {/each}
      {#if mobile}
        <button role="tab" class="tab" class:on={route === "settings"} aria-selected={route === "settings"} onclick={() => (route = "settings")} title="Settings"><Icon name="settings" /><span>Settings</span></button>
      {/if}
    </div>
    {#if !mobile}
      <div class="rule"></div>
      <div class="side-list" id="sidebar-slot">
        {#if route === "chat" && showList}<NookList />{/if}
      </div>
      <div class="footer">
        <span class="status" title={status}><span class="dot" class:waiting={nook.waiting > 0} class:working={nook.working > 0} class:unread={!nook.waiting && !nook.working && !!nook.info?.brainReady}></span><span class="status-text">{status}</span></span>
        <span class="spacer"></span>
        <button class="ghost icon-button" class:on={route === "settings"} aria-current={route === "settings" ? "page" : undefined} onclick={() => (route = "settings")} title="Settings (Ctrl+,)" aria-label="Settings"><Icon name="settings" /></button>
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
            <button class="ghost icon-button" onclick={() => (showList = !showList)} title={showList ? "Hide conversations" : "Show conversations"} aria-label={mobile ? "Back to conversations" : "Toggle conversations"} aria-expanded={showList}><Icon name={mobile ? "back" : "sidebar"} /></button>
            <span class="name">{nook.active?.title ?? "New Nook"}</span>
            <span class="spacer"></span>
            <button class="ghost icon-button" disabled={!nook.active?.messages.length} onclick={copyConversation} title="Copy conversation as Markdown" aria-label="Copy conversation as Markdown"><Icon name="copy" /></button>
            <button class="ghost icon-button" onclick={() => { nook.newNook(); if (mobile) showList = false; }} title="New Nook (Ctrl+N)" aria-label="New Nook"><Icon name="plus" /></button>
          </header>
          <Chat />
        </div>
      </div>
    {:else if route === "chats"}
      <header class="title page-title"><span class="name">{routeTitle}</span></header>
      <div class="route-body"><Chats onnook={(id) => { nook.select(id); route = "chat"; }} /></div>
    {:else}
      <header class="title page-title"><span class="name">{routeTitle}</span></header>
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
  .head { display: flex; align-items: center; gap: 4px; height: 52px; padding: 0 4px; flex: none; }
  .tabbar { display: flex; gap: 2px; padding: 2px; min-height: 34px; background: var(--surface); border-radius: var(--radius-card); flex: none; }
  .tab { display: flex; align-items: center; justify-content: center; gap: 6px; flex: 0 0 auto; min-width: 28px; height: 30px; padding: 0; background: transparent; border: 0; border-radius: var(--radius-control); color: var(--text3); font-size: 13px; font-weight: 500; }
  .tab:not(.on) { flex: 1 1 0; }
  .tab span { display: none; }
  .tab.on { padding: 0 10px; background: var(--row-selected); color: var(--paper); }
  .tab.on span { display: inline; }
  .tab:hover:not(.on) { color: var(--text2); background: var(--row-hover); }
  .rule { height: 1px; background: var(--border); margin: 8px 0 4px; flex: none; }
  .side-list { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .side-list :global(.list) { flex: 1; background: transparent; border-right: 0; }
  .footer { display: flex; align-items: center; gap: 4px; padding: 6px 4px 0; flex: none; }
  .status { display: flex; align-items: center; gap: 8px; min-width: 0; font-size: 12px; color: var(--text3); }
  .status-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .status .dot { background-color: var(--text3); }
  .status .dot.waiting { background-color: var(--amber); }
  .status .dot.working { background-color: var(--paper); }
  .status .dot.unread { background-color: var(--mint); }
  .spacer { flex: 1; }
  .icon-button { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; flex-shrink: 0; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .icon-button.on { background: var(--row-selected); color: var(--paper); }
  .content { min-width: 0; min-height: 0; height: 100%; overflow: hidden; display: flex; flex-direction: column; background: var(--canvas); }
  .chatlayout { display: grid; grid-template-columns: minmax(0, 1fr); height: 100%; }
  .chatpane { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap :global(.list) { flex: 1; }
  .title { min-height: 52px; padding: 0 16px; display: flex; align-items: center; gap: 8px; min-width: 0; flex-shrink: 0; }
  .title .name { font-size: 15px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .page-title { border-bottom: 1px solid var(--border); }
  .route-body { flex: 1; min-height: 0; overflow: hidden; }
  .chatpane :global(.chat) { flex: 1; min-height: 0; }
  @media (min-width: 641px) and (max-width: 860px) {
    .main { grid-template-columns: 56px minmax(0, 1fr); }
    .rail { padding: 0 6px 8px; }
    .head :global(.orb), .head .spacer, .status-text { display: none; }
    .tabbar { flex-direction: column; background: transparent; }
    .tab, .tab.on, .tab:not(.on) { flex: none; width: 36px; height: 36px; padding: 0; }
    .tab.on span { display: none; }
    .side-list { display: none; }
  }
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
