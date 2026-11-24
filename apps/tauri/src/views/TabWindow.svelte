<script lang="ts">
  // A tab in a window of its own (the Mac's `TabWindowController` with `PanelTabContent(ownWindow:)`): the Nook chat,
  // Agents, Chats or Music, each with its own list, and one button that puts it back beside the main tab.
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import { TAB_MARKS, tabFromLocation, type SplitTab } from "../lib/panel-split";
  import { dockTabWindow } from "../lib/tab-windows.svelte";
  import { routeViews } from "../lib/shell-routes";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import { api } from "../lib/api";
  import type { Target } from "../lib/inbox";
  import { showChat } from "../lib/chat-arrived.svelte";
  import { toast } from "../lib/toast.svelte";
  import { tip } from "../components/ui/tip";
  import Ico from "../components/ui/Ico.svelte";
  import Chat from "../components/Chat.svelte";
  import Chats from "./Chats.svelte";
  import Music from "./services/Music.svelte";
  import LazyView from "../components/LazyView.svelte";

  const tab: SplitTab = tabFromLocation(location.search) ?? "chat";
  const titles = $derived<Record<SplitTab, string>>({
    chat: "Nook",
    agents: "Agents",
    chats: tr("Chats", "Chats"),
    music: tr("Muziek", "Music"),
  });

  let playing = $state<NowPlaying | null>(null);
  let since = $state(Date.now());
  $effect(() => {
    if (tab !== "music") return;
    services.nowPlaying().then((n) => ((playing = n), (since = Date.now()))).catch(() => {});
    const un = serviceEvents.onNowPlaying((n) => ((playing = n), (since = Date.now())));
    return () => { un.then((f) => f()); };
  });

  /// What the chat in this window points at outside itself (Settings, a session, a page) opens in the main window; a
  /// Nook opens right here.
  function openElsewhere(target: Target) {
    const route = target.kind === "settings" ? `settings:${target.section}`
      : target.kind === "route" ? target.route
      : target.kind === "agents" ? "agents"
      : target.kind === "workspace" ? "workspace"
      : null;
    if (target.kind === "nook") nook.select(target.id).catch(() => {});
    else if (target.kind === "chat") api.showMain("chats").then(() => showChat(target.key, true)).catch(() => {});
    else if (target.kind === "newNook") nook.newNook().then(async () => { if (target.ask) await nook.ask(target.ask); }).catch(() => {});
    else if (route) api.showMain(route).catch(() => {});
  }

  async function dock() {
    try { await dockTabWindow(tab); }
    catch (e) { toast.error(tr("Kon het venster niet sluiten", "Could not close the window"), e); }
  }
</script>

<div class="tab-window">
  <header class="head">
    <span class="mark"><Ico name={TAB_MARKS[tab]} size={14} /></span>
    <span class="title">{titles[tab]}</span>
    <span class="spacer"></span>
    <button class="ghost icon-button" onclick={dock} use:tip={tr("Terug naast de hoofdtab", "Back beside the main tab")} aria-label={tr("Terug naast de hoofdtab", "Back beside the main tab")}><Ico name="columns-2" size={14} /></button>
  </header>
  <div class="body">
    {#if !nook.info}
      <p class="faint quiet">{tr("Laden…", "Loading…")}</p>
    {:else if tab === "chat"}
      <div class="chat-wrap"><Chat onopen={openElsewhere} /></div>
    {:else if tab === "chats"}
      <Chats onnook={(id) => nook.select(id)} />
    {:else if tab === "music"}
      {#if playing}<Music info={playing} {since} />{:else}<p class="faint quiet">{tr("Er speelt nu niets.", "Nothing is playing right now.")}</p>{/if}
    {:else}
      <LazyView load={routeViews.agents!} label="Agents" props={{ compact: true }} />
    {/if}
  </div>
</div>

<style>
  .tab-window { display: flex; flex-direction: column; height: 100dvh; overflow: hidden; background: var(--canvas); }
  .head { display: flex; align-items: center; gap: var(--space-6); min-height: 44px; padding: 0 var(--space-8) 0 var(--space-16); border-bottom: 1px solid var(--hairline); flex: none; }
  .mark { display: inline-flex; color: var(--text2); }
  .title { font: var(--text-emphasis); color: var(--paper); }
  .spacer { flex: 1; }
  .icon-button { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .icon-button:hover { background: var(--row-hover); color: var(--paper); }
  .body { flex: 1; min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
  .body > :global(*) { flex: 1; min-height: 0; }
  .chat-wrap { display: flex; flex-direction: column; min-height: 0; }
  .chat-wrap :global(.chat) { flex: 1; min-height: 0; }
  .quiet { padding: var(--space-24); text-align: center; }
</style>
