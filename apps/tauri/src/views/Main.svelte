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

  type Route = "chat" | "agents" | "workspace" | "settings";
  let route = $state<Route>("chat");
  let showList = $state(true);
  const mobile = $derived(nook.info?.capabilities.os === "android");

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

<svelte:window onkeydown={keys} />

<div class="main" class:mobile>
  <nav class="rail">
    <div class="brand"><Orb size={24} mood={nook.waiting ? "waiting" : nook.working ? "working" : "idle"} /></div>
    <button class:on={route === "chat"} onclick={() => { if (route === "chat") showList = !showList; route = "chat"; }} title="Chat">💬<span>Chat</span></button>
    <button class:on={route === "agents"} onclick={() => (route = "agents")} title="Agents">⌘<span>Agents</span></button>
    {#if nook.info?.capabilities.terminals}
      <button class:on={route === "workspace"} onclick={() => (route = "workspace")} title="Werkruimte">▤<span>Werkruimte</span></button>
    {/if}
    <span class="spacer"></span>
    <button class:on={route === "settings"} onclick={() => (route = "settings")} title="Instellingen">⚙<span>Instellingen</span></button>
  </nav>
  <section class="content">
    {#if route === "chat"}
      <div class="chatlayout" class:nolist={!showList}>
        {#if showList}<NookList />{/if}
        <div class="chatpane">
          <div class="title">
            {#if mobile}<button class="ghost" onclick={() => (showList = true)}>‹</button>{/if}
            {nook.active?.title ?? "Nieuwe Nook"}
          </div>
          <Chat />
        </div>
      </div>
    {:else if route === "agents"}
      <Agents />
    {:else if route === "workspace"}
      <Workspace />
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
  .title { padding: 12px 16px; border-bottom: 1px solid var(--line); font-weight: 600; }
  .chatpane :global(.chat) { flex: 1; min-height: 0; }

  /* Android: de navigatie onderaan, de lijst als eigen scherm. */
  .main.mobile { grid-template-columns: 1fr; grid-template-rows: 1fr 60px; }
  .main.mobile .rail { flex-direction: row; justify-content: space-around; padding: 0 8px env(safe-area-inset-bottom); order: 2; }
  .main.mobile .brand, .main.mobile .spacer { display: none; }
  .main.mobile .content { height: calc(100vh - 60px); }
  .main.mobile .chatlayout { grid-template-columns: 1fr; }
  .main.mobile .chatlayout:not(.nolist) .chatpane { display: none; }
</style>
