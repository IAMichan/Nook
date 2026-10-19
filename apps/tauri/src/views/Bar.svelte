<script lang="ts">
  // De balk bovenaan het scherm: in rust een pil met Nook, open een paneel met de tabs Nook, Agents en Werkruimte.
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import Orb from "../components/Orb.svelte";
  import Today from "./Today.svelte";
  import Agents from "./Agents.svelte";
  import Workspace from "./Workspace.svelte";

  type Tab = "nook" | "agents" | "workspace";
  let expanded = $state(false);
  let tab = $state<Tab>((localStorage.getItem("bar.tab") as Tab) || "nook");
  let pinnedOpen = $state(false);
  let closeTimer: ReturnType<typeof setTimeout> | undefined;

  const mood = $derived(nook.waiting ? "waiting" : nook.working ? "working" : "idle");
  const floating = $derived(nook.settings?.placement === "floating");

  async function open(focus?: string) {
    clearTimeout(closeTimer);
    if (!expanded) {
      expanded = true;
      await api.barExpand(true);
    }
    if (focus === "chat" || focus === "voice") {
      tab = "nook";
      pinnedOpen = true;
    }
  }

  async function close() {
    if (!expanded) return;
    expanded = false;
    pinnedOpen = false;
    await api.barExpand(false);
  }

  function leave() {
    if (pinnedOpen || nook.busy) return;
    closeTimer = setTimeout(close, 450);
  }

  function select(t: Tab) {
    tab = t;
    localStorage.setItem("bar.tab", t);
  }

  async function drag(e: MouseEvent) {
    if (!floating || e.button !== 0) return;
    await getCurrentWindow().startDragging();
    await api.barMoved();
  }

  $effect(() => {
    const un = events.onBarOpen((focus) => open(focus));
    return () => {
      un.then((f) => f());
    };
  });
</script>

<svelte:window onkeydown={(e) => e.key === "Escape" && close()} onblur={() => !nook.busy && close()} />

<div class="bar" class:expanded class:floating role="region" onmouseenter={() => open()} onmouseleave={leave}>
  {#if !expanded}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="pill" onmousedown={drag}>
      <Orb size={20} {mood} />
      {#if nook.working}<span class="dot working"></span>{/if}
      {#if nook.waiting}<span class="dot waiting"></span>{/if}
    </div>
  {:else}
    <div class="panel">
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <header onmousedown={drag}>
        <Orb size={20} {mood} />
        <nav>
          <button class:on={tab === "nook"} onclick={() => select("nook")}>Nook {#if nook.waiting}<span class="dot waiting"></span>{/if}</button>
          <button class:on={tab === "agents"} onclick={() => select("agents")}>Agents</button>
          {#if nook.info?.capabilities.terminals}
            <button class:on={tab === "workspace"} onclick={() => select("workspace")}>Werkruimte</button>
          {/if}
        </nav>
        <span class="spacer"></span>
        <button class="ghost icon" title="Open in venster" onclick={() => api.showMain("chat")}>⧉</button>
        <button class="ghost icon" title="Instellingen" onclick={() => api.showMain("settings")}>⚙</button>
      </header>
      <div class="body">
        {#if tab === "nook"}
          <div class="nooktab">
            <div class="chatcol"><Chat compact autofocus={pinnedOpen} /></div>
            <div class="side"><Today /></div>
          </div>
        {:else if tab === "agents"}
          <Agents compact />
        {:else}
          <Workspace compact />
        {/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .bar { width: 100vw; height: 100vh; display: flex; justify-content: center; align-items: flex-start; }
  .pill {
    height: 100%;
    width: 100%;
    background: var(--notch);
    border-radius: 0 0 16px 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    cursor: default;
  }
  .floating .pill { border-radius: 999px; cursor: grab; }
  .panel {
    width: 100%;
    height: 100%;
    background: var(--notch);
    border-radius: 0 0 22px 22px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    animation: drop 0.32s cubic-bezier(0.2, 1.2, 0.4, 1);
    transform-origin: top center;
  }
  .floating .panel { border-radius: 22px; }
  @keyframes drop { from { transform: scaleY(0.7); opacity: 0; } }
  header { display: flex; align-items: center; gap: 10px; padding: 10px 12px 6px; }
  nav { display: flex; gap: 4px; }
  nav button { background: transparent; border: none; color: var(--text2); border-radius: 999px; padding: 5px 12px; display: flex; gap: 6px; align-items: center; }
  nav button.on { background: var(--smoke); color: var(--paper); }
  .spacer { flex: 1; }
  .icon { padding: 4px 8px; }
  .body { flex: 1; min-height: 0; }
  .nooktab { display: grid; grid-template-columns: 1fr 220px; height: 100%; }
  .chatcol { min-height: 0; }
  .side { border-left: 1px solid var(--line); overflow-y: auto; }
  .panel :global(.composer) { background: var(--notch); }
</style>
