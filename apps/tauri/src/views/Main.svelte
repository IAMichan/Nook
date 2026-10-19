<script lang="ts">
  // Het hoofdvenster (en de hele app op Android): Chat met al je Nooks, Agents, Werkruimte en Instellingen.
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import NookList from "../components/NookList.svelte";
  import Orb from "../components/Orb.svelte";
  import Settings from "./Settings.svelte";
  import Agents from "./Agents.svelte";
  import Workspace from "./Workspace.svelte";
  import Companion from "./companion/Companion.svelte";
  import { companion } from "../lib/companion";
  import { onBack, setupMobile } from "../lib/mobile";

  type Route = "chat" | "agents" | "workspace" | "companion" | "settings";
  let route = $state<Route>("chat");
  let showList = $state(true);
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

  function keys(e: KeyboardEvent) {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === "n") {
      e.preventDefault();
      route = "chat";
      nook.newNook();
    } else if (mod && e.key === ",") {
      e.preventDefault();
      route = "settings";
    } else if (mod && e.key === ".") {
      nook.stop();
    }
  }
</script>

<svelte:window onkeydown={keys} bind:innerWidth={width} />

<div class="main" class:mobile>
  <nav class="rail">
    <div class="brand"><Orb size={24} mood={nook.waiting ? "waiting" : nook.working ? "working" : "idle"} /></div>
    <button class:on={route === "chat"} onclick={() => { if (route === "chat") showList = !showList; route = "chat"; }} title="Chat">💬<span>Chat</span></button>
    <button class:on={route === "agents"} onclick={() => (route = "agents")} title="Agents">⌘<span>Agents</span></button>
    {#if nook.info?.capabilities.terminals}
      <button class:on={route === "workspace"} onclick={() => (route = "workspace")} title="Werkruimte">▤<span>Werkruimte</span></button>
    {/if}
    {#if companionClient}
      <button class:on={route === "companion"} onclick={() => (route = "companion")} title="Companion">📱<span>Companion</span></button>
    {/if}
    <span class="spacer"></span>
    <button class:on={route === "settings"} onclick={() => (route = "settings")} title="Instellingen">⚙<span>Instellingen</span></button>
  </nav>
  <section class="content">
    {#if route === "chat"}
      <div class="chatlayout" class:nolist={!showList}>
        {#if showList}
          <!-- Op de telefoon opent een Nook kiezen het gesprek, ook als het al de actieve was. -->
          <div class="listwrap" role="presentation" onclick={(e) => {
            const t = e.target as HTMLElement;
            if (mobile && t.closest(".item") && !t.closest(".menu")) showList = false;
          }}>
            <NookList />
          </div>
        {/if}
        <div class="chatpane">
          <div class="title">
            {#if mobile}<button class="ghost back" onclick={() => (showList = true)} aria-label="Terug naar je Nooks">‹</button>{/if}
            <span class="name">{nook.active?.title ?? "Nieuwe Nook"}</span>
          </div>
          <Chat />
        </div>
      </div>
    {:else if route === "agents"}
      <Agents />
    {:else if route === "workspace"}
      <Workspace />
    {:else if route === "companion"}
      <Companion />
    {:else}
      <Settings />
    {/if}
  </section>
</div>

<style>
  .main { display: grid; grid-template-columns: 64px 1fr; height: 100vh; }
  .rail { background: var(--notch); display: flex; flex-direction: column; align-items: center; gap: 4px; padding: 12px 0; }
  .brand { margin-bottom: 12px; }
  .rail button { width: 52px; background: none; border: none; color: var(--text2); display: flex; flex-direction: column; align-items: center; gap: 2px; font-size: 16px; padding: 6px 0; border-radius: 10px; }
  .rail button span { font-size: 10px; }
  .rail button.on, .rail button:hover { color: var(--paper); background: var(--smoke); }
  .spacer { flex: 1; }
  .content { min-width: 0; min-height: 0; height: 100vh; overflow: hidden; }
  .chatlayout { display: grid; grid-template-columns: 260px 1fr; height: 100%; }
  .chatlayout.nolist { grid-template-columns: 1fr; }
  .chatpane { display: flex; flex-direction: column; min-height: 0; }
  .listwrap { display: flex; flex-direction: column; min-height: 0; }
  .listwrap :global(.list) { flex: 1; }
  .title { padding: 12px 16px; border-bottom: 1px solid var(--line); font-weight: 600; display: flex; align-items: center; gap: 4px; min-width: 0; }
  .title .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .chatpane :global(.chat) { flex: 1; min-height: 0; }

  /* De telefoon: navigatie onderaan, de lijst als eigen scherm, ruimte voor notch, gebarenbalk en toetsenbord
     (--safe-* en --keyboard komen van Android, zie lib/mobile.ts). */
  .main.mobile {
    grid-template-columns: 1fr; grid-template-rows: 1fr auto; height: 100dvh;
    padding: var(--safe-top) var(--safe-right) 0 var(--safe-left);
  }
  .main.mobile .rail { flex-direction: row; justify-content: space-around; padding: 4px 8px calc(4px + var(--safe-bottom)); order: 2; gap: 0; border-top: 1px solid var(--line); }
  .main.mobile .rail button { flex: 1; max-width: 96px; min-height: 52px; font-size: 18px; }
  .main.mobile .rail button span { font-size: 11px; }
  .main.mobile .brand, .main.mobile .spacer { display: none; }
  .main.mobile .content { height: auto; min-height: 0; }
  .main.mobile .chatlayout { grid-template-columns: 1fr; }
  .main.mobile .chatlayout:not(.nolist) .chatpane { display: none; }
  .main.mobile .chatlayout:not(.nolist) :global(.list) { border-right: none; }
  .main.mobile .title { padding: 6px 12px 6px 4px; }
  .main.mobile .back { min-width: 44px; min-height: 44px; font-size: 26px; line-height: 1; padding: 0; }
  /* Met het toetsenbord open: de navigatie weg, het invoerveld net boven het toetsenbord. */
  :global(html.keyboard-open) .main.mobile { padding-bottom: var(--keyboard); }
  :global(html.keyboard-open) .main.mobile .rail { display: none; }
</style>
