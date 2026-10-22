<script lang="ts">
  // Het hoofdvenster (en de hele app op Android): Chat met al je Nooks, Agents, Werkruimte en Instellingen.
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import NookList from "../components/NookList.svelte";
  import Orb from "../components/Orb.svelte";
  import Icon from "../components/Icon.svelte";
  import CommandPalette from "../components/CommandPalette.svelte";
  import { conversationMarkdown } from "../lib/conversation-export";
  import { toast } from "../lib/toast.svelte";
  import Settings from "./Settings.svelte";
  import Agents from "./Agents.svelte";
  import Workspace from "./Workspace.svelte";
  import Companion from "./companion/Companion.svelte";
  import { companion } from "../lib/companion";
  import { onBack, setupMobile } from "../lib/mobile";

  type Route = "chat" | "agents" | "workspace" | "companion" | "settings";
  let route = $state<Route>("chat");
  let showList = $state(true);
  let paletteOpen = $state(false);
  let width = $state(window.innerWidth);
  const android = $derived(nook.info?.capabilities.os === "android");
  // De telefoonindeling: op Android, en in een smal venster op de computer.
  const mobile = $derived(android || width <= 640);
  let companionClient = $state(false);

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
    if (route === "chat" && mobile && !showList) return (showList = true), true;
    if (route !== "chat") return (route = "chat"), true;
    return false;
  }));

  $effect(() => {
    api.takeRoute().then((r) => r && (route = r as Route));
    const un = events.onNavigate((r) => {
      route = (r as Route) || "chat";
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

  const routeTitle = $derived(({ chat: "Chat", agents: "Agents", workspace: "Workspace", companion: "Companion", settings: "Settings" })[route]);
  const status = $derived(nook.waiting ? "Waiting for you" : nook.working ? "Working" : nook.info?.brainReady ? "Ready" : "Set up your brain");

  function keys(e: KeyboardEvent) {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === "k") {
      e.preventDefault();
      paletteOpen = !paletteOpen;
    } else if (mod && e.key.toLowerCase() === "b" && route === "chat" && !paletteOpen) {
      e.preventDefault();
      showList = !showList;
    } else if (mod && e.key.toLowerCase() === "n" && !paletteOpen) {
      e.preventDefault();
      route = "chat";
      showList = !mobile;
      nook.newNook();
    } else if (mod && e.key === ",") {
      e.preventDefault();
      route = "settings";
    } else if (mod && e.key === ".") {
      nook.stop();
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
    <div class="brand"><Orb size={28} mood={nook.waiting ? "waiting" : nook.working ? "working" : "idle"} /><div><strong>Nook</strong><span>Your personal assistant</span></div></div>
    <span class="nav-label">WORKSPACE</span>
    <button class="quick-open" onclick={() => (paletteOpen = true)} title="Quick switcher (Ctrl+K)"><Icon name="search" /><span>{mobile ? "Search" : "Quick switcher"}</span><kbd>Ctrl K</kbd></button>
    <button class:on={route === "chat"} aria-current={route === "chat" ? "page" : undefined} onclick={() => { if (route === "chat" && mobile) showList = !showList; route = "chat"; }} title="Chat"><Icon name="chat" /><span>Chat</span></button>
    <button class:on={route === "agents"} aria-current={route === "agents" ? "page" : undefined} onclick={() => (route = "agents")} title="Agents"><Icon name="agents" /><span>Agents</span></button>
    {#if nook.info?.capabilities.terminals}
      <button class:on={route === "workspace"} aria-current={route === "workspace" ? "page" : undefined} onclick={() => (route = "workspace")} title="Workspace"><Icon name="workspace" /><span>Workspace</span></button>
    {/if}
    {#if companionClient}
      <button class:on={route === "companion"} aria-current={route === "companion" ? "page" : undefined} onclick={() => (route = "companion")} title="Companion"><Icon name="phone" /><span>Companion</span></button>
    {/if}
    <span class="spacer"></span>
    <div class="rail-status"><span class="dot" class:waiting={nook.waiting > 0} class:working={nook.working > 0} class:unread={!nook.waiting && !nook.working && !!nook.info?.brainReady}></span><span>{status}</span></div>
    <button class:on={route === "settings"} aria-current={route === "settings" ? "page" : undefined} onclick={() => (route = "settings")} title="Settings (Ctrl+,)"><Icon name="settings" /><span>Settings</span><kbd>Ctrl ,</kbd></button>
  </nav>
  <section class="content" aria-label={routeTitle}>
    {#if route === "chat"}
      <div class="chatlayout" class:nolist={!showList}>
        {#if showList}
          <div class="listwrap" role="presentation" onclick={(e) => {
            const t = e.target as HTMLElement;
            if (mobile && t.closest(".item") && !t.closest(".menu") && !t.closest(".menu-trigger")) showList = false;
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
    {:else}
      <header class="title page-title"><span class="name">{routeTitle}</span><span class="page-caption">{route === "settings" ? "Make Nook yours" : route === "agents" ? "Your coding sessions, together" : route === "workspace" ? "Tools for your next idea" : "Stay connected"}</span></header>
      <div class="route-body">
        {#if route === "agents"}<Agents />
        {:else if route === "workspace"}<Workspace />
        {:else if route === "companion"}<Companion />
        {:else}<Settings />{/if}
      </div>
    {/if}
  </section>
</div>
{#if paletteOpen}<CommandPalette onclose={() => (paletteOpen = false)} onnavigate={navigate} companionEnabled={companionClient} />{/if}

<style>
  .main { display: grid; grid-template-columns: 192px minmax(0, 1fr); height: 100dvh; overflow: hidden; }
  .rail { background: var(--sidebar); border-right: 1px solid var(--line); display: flex; flex-direction: column; gap: 5px; padding: 26px 12px 12px; }
  .brand { display: flex; align-items: center; gap: 10px; margin: 0 8px 36px; }
  .brand strong { font-size: 21px; font-weight: 650; letter-spacing: -.7px; }
  .brand span { display: block; color: var(--text3); font-size: 10px; margin-top: 2px; }
  .nav-label { font-size: 10px; font-weight: 650; letter-spacing: 1.5px; color: var(--text3); padding: 0 12px 9px; }
  .rail button { position: relative; display: flex; align-items: center; gap: 11px; min-height: 42px; padding: 10px 12px; background: transparent; border: 1px solid transparent; color: var(--text2); text-align: left; }
  .rail button.on { color: var(--paper); background: var(--smoke); border-color: var(--line2); box-shadow: var(--shadow-control); }
  .rail button.on::before { content: ""; position: absolute; left: -13px; height: 18px; width: 3px; background: var(--iris); border-radius: var(--radius-control); }
  .rail button:hover { color: var(--paper); background: var(--row-hover); }
  .rail kbd { margin-left: auto; font-size: 9px; opacity: .65; }
  .rail-status { display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--text3); padding: 16px 12px; border-bottom: 1px solid var(--line); margin-bottom: 5px; }
  .rail-status .dot { background-color: var(--text3); }
  .rail-status .dot.waiting { background-color: var(--amber); }
  .rail-status .dot.working { background-color: var(--paper); }
  .rail-status .dot.unread { background-color: var(--mint); }
  .spacer { flex: 1; }
  .content { min-width: 0; min-height: 0; height: 100%; overflow: hidden; display: flex; flex-direction: column; background: var(--canvas); }
  .chatlayout { display: grid; grid-template-columns: 250px minmax(0, 1fr); height: 100%; }
  .chatlayout.nolist { grid-template-columns: minmax(0, 1fr); }
  .chatpane { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap :global(.list) { flex: 1; }
  .title { min-height: 64px; padding: 12px 22px; border-bottom: 1px solid var(--line); display: flex; align-items: center; gap: 12px; min-width: 0; flex-shrink: 0; }
  .title .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .icon-button { display: grid; place-items: center; width: 32px; height: 32px; padding: 0; flex-shrink: 0; }
  .page-title { padding-inline: 28px; }
  .page-caption { color: var(--text3); font-size: 12px; margin-left: auto; }
  .route-body { flex: 1; min-height: 0; overflow: hidden; }
  .chatpane :global(.chat) { flex: 1; min-height: 0; }
  @media (min-width: 641px) and (max-width: 1000px) {
    .main { grid-template-columns: 72px minmax(0, 1fr); }
    .brand { margin: 0 auto 28px; }
    .brand div, .nav-label, .rail button span, .rail kbd, .rail-status { display: none; }
    .rail button { justify-content: center; padding-inline: 0; }
    .chatlayout { grid-template-columns: 222px minmax(0, 1fr); }
  }
  .main.mobile { grid-template-columns: minmax(0, 1fr); grid-template-rows: 1fr auto; padding: var(--safe-top) var(--safe-right) 0 var(--safe-left); }
  .main.mobile .rail { flex-direction: row; justify-content: space-around; padding: 4px 8px calc(4px + var(--safe-bottom)); order: 2; gap: 0; border-top: 1px solid var(--line); border-right: 0; }
  .main.mobile .rail button { flex: 1; flex-direction: column; max-width: 96px; min-height: 54px; gap: 4px; padding: 7px 4px; }
  .main.mobile .rail button span { font-size: 10px; }
  .main.mobile .rail button.on::before, .main.mobile .brand, .main.mobile .spacer, .main.mobile .nav-label, .main.mobile .rail-status, .main.mobile kbd { display: none; }
  .main.mobile .chatlayout { grid-template-columns: minmax(0, 1fr); }
  .main.mobile .chatlayout:not(.nolist) .chatpane { display: none; }
  .main.mobile .chatlayout:not(.nolist) :global(.list) { border-right: none; }
  .main.mobile .title { min-height: 56px; padding: 8px 12px; }
  .main.mobile .page-caption { display: none; }
  :global(html.keyboard-open) .main.mobile { padding-bottom: var(--keyboard); }
  :global(html.keyboard-open) .main.mobile .rail { display: none; }
</style>
