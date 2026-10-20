<script lang="ts">
  // De balk bovenaan het scherm: in rust een pil met Nook, open een paneel met de tabs Nook, Agents en Werkruimte.
  import { untrack } from "svelte";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import Orb from "../components/Orb.svelte";
  import Today from "./Today.svelte";
  import Agents from "./Agents.svelte";
  import Workspace from "./Workspace.svelte";
  import Music from "./services/Music.svelte";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import { listening } from "../lib/listening.svelte";
  import { attachments } from "../lib/attachments.svelte";
  import { play } from "../lib/sounds";
  import { agents } from "../lib/agents.svelte";
  import AgentAlerts from "./agents/AgentAlerts.svelte";
  import AgentDots from "./agents/AgentDots.svelte";
  import NoticeMark from "../components/NoticeMark.svelte";
  import NoticeOk from "../components/NoticeOk.svelte";
  import { compactNotice, Countdown, noticeTone } from "../lib/notice";
  import WhatsAppCard from "./connectors/WhatsAppCard.svelte";
  import { whatsapp } from "../lib/whatsapp.svelte";

  type Tab = "nook" | "agents" | "workspace" | "music";
  let expanded = $state(false);
  let tab = $state<Tab>((localStorage.getItem("bar.tab") as Tab) || "nook");
  let pinnedOpen = $state(false);
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  let inside = $state(false);
  // Agent notices: a compact one widens the closed bar (`strip`); a detailed one opens the panel. `noticeLeft` is what
  // is left of its countdown, for the ring on OK.
  let strip = $state(false);
  let openedForNotice = false;
  let noticeLeft = $state<number | null>(null);
  const noticeCompact = $derived(nook.settings?.agentNotice === "compact");

  const mood = $derived(nook.waiting ? "waiting" : nook.working ? "working" : "idle");
  const floating = $derived(nook.settings?.placement === "floating");

  async function open(focus?: string) {
    clearTimeout(closeTimer);
    const wasExpanded = expanded;
    if (!expanded) {
      strip = false;
      expanded = true;
      await api.barExpand(true);
      // Het aanbod naast de balk zou het paneel bedekken; het staat ook in Vandaag.
      services.asideHide();
    }
    if (focus === "chat" || focus === "voice" || focus === "lookAlong") {
      tab = "nook";
      pinnedOpen = true;
    } else if (focus === "agents") {
      tab = "agents";
      pinnedOpen = true;
    } else if (focus === "agents-request" && !wasExpanded) {
      // A permission request or question: a closed bar opens on the agents; an open panel stays as it was and asks in
      // its compact bar under the tabs.
      tab = "agents";
      pinnedOpen = true;
    }
    if (focus === "voice") listening.start();
    if (focus?.startsWith("nook:")) {
      tab = "nook";
      pinnedOpen = true;
      await nook.select(focus.slice(5));
    }
    if (focus === "lookAlong") services.lookAlong().catch((e) => (nook.error = String(e)));
  }

  // Muziek: een eigen tab zolang er iets speelt.
  let playing = $state<NowPlaying | null>(null);
  let since = $state(Date.now());
  // De gekozen tab, of Nook als die tab er nu niet is (niets speelt, of geen terminals op dit platform).
  const shown = $derived<Tab>(
    (tab === "music" && !playing) || (tab === "workspace" && nook.info && !nook.info.capabilities.terminals) ? "nook" : tab,
  );
  $effect(() => {
    services.nowPlaying().then((n) => ((playing = n), (since = Date.now()))).catch(() => {});
    const un = serviceEvents.onNowPlaying((n) => {
      playing = n;
      since = Date.now();
      if (!n && tab === "music") tab = "nook";
    });
    return () => {
      un.then((f) => f());
    };
  });

  // Geluiden: aandacht als een Nook op je wacht, klaar als hij af is.
  let statuses = new Map<string, string>();
  $effect(() => {
    const next = new Map(nook.nooks.map((n) => [n.id, n.status as string]));
    for (const [id, status] of next) {
      const before = statuses.get(id);
      if (before && before !== status) {
        if (status === "waiting") play("attention", nook.settings?.sounds ?? true);
        else if (before === "working" && (status === "unread" || status === "idle")) play("done", nook.settings?.sounds ?? true);
      }
    }
    statuses = next;
  });

  // De ring om Nook in het open paneel: alles waar hij mee bezig is of wat op je wacht.
  const ring = $derived(
    nook.nooks
      .filter((n) => n.status === "working" || n.status === "waiting")
      .map((n) => ({ id: n.id, label: n.title, state: n.status as "working" | "waiting" })),
  );

  async function close() {
    if (!expanded) return;
    expanded = false;
    pinnedOpen = false;
    await api.barExpand(false);
    services.asideShow();
  }

  function leave() {
    inside = false;
    // A notice closes the bar itself, once its countdown has run out with the pointer off the bar.
    if (pinnedOpen || nook.busy || agents.pending || agents.attention || whatsapp.chat) return;
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

  // Agents: geluiden in de balk, en het kaartje "klaar" klapt hem even open (tot je ernaar wijst).
  $effect(() => {
    agents.sounds = true;
    agents.start();
  });
  // A notice stays for its countdown with the pointer off the bar (hovering holds it), or until OK, View or Esc.
  // Detailed opens the panel with a card; compact widens the closed bar into one line.
  $effect(() => {
    const card = agents.attention;
    if (!card) return;
    untrack(() => {
      if (expanded) return;
      if (noticeCompact) {
        strip = true;
        api.barExpand(false, true);
      } else {
        openedForNotice = true;
        open();
      }
    });
    const clock = new Countdown();
    noticeLeft = 1;
    let last = performance.now();
    const timer = setInterval(() => {
      const now = performance.now();
      clock.advance((now - last) / 1000, inside);
      last = now;
      noticeLeft = clock.fraction;
      if (clock.done && agents.attention === card) agents.attention = null;
    }, 100);
    return () => {
      clearInterval(timer);
      // A newer notice took its place: it carries on from here.
      if (agents.attention) return;
      noticeLeft = null;
      openedForNotice = false;
      if (strip) {
        strip = false;
        if (!expanded) api.barExpand(false);
      }
      if (expanded && !inside) leave();
    };
  });

  function dismissNotice() {
    agents.attention = null;
  }

  function viewNotice(id: string) {
    agents.attention = null;
    agents.select(id);
    select("agents");
    pinnedOpen = true;
    open();
  }

  // WhatsApp: a new message opens the bar with its card, which stays until you answer or close it.
  $effect(() => {
    whatsapp.start();
  });
  $effect(() => {
    if (whatsapp.chat && !untrack(() => expanded)) untrack(() => open());
  });

  // Escape first shrinks an enlarged photo, then closes the WhatsApp card, then the bar.
  function escape() {
    if (whatsapp.enlarged) whatsapp.enlarged = null;
    else if (whatsapp.chat) whatsapp.dismiss();
    else {
      if (agents.attention) dismissNotice();
      close();
    }
  }

  $effect(() => {
    attachments.start();
    const un = events.onBarOpen((focus) => open(focus));
    return () => {
      un.then((f) => f());
    };
  });
</script>

<svelte:window onkeydown={(e) => e.key === "Escape" && escape()} onblur={() => !nook.busy && !agents.pending && !whatsapp.chat && close()} />

<div class="bar" class:expanded class:floating role="region" onmouseenter={() => { inside = true; if (!strip) open(); }} onmouseleave={leave}>
  {#if !expanded && strip && agents.attention}
    {@const card = agents.attention}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="pill strip" onmousedown={drag}>
      <NoticeMark tone={noticeTone(card.status)} size={card.status === "done" || card.status === "failed" ? 13 : 15} />
      <span class="message">{compactNotice(card.name, card.project, card.status)}</span>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="stripbuttons" onmousedown={(e) => e.stopPropagation()}>
        <button class="ghost" onclick={() => viewNotice(card.id)}>Bekijk</button>
        <NoticeOk compact left={noticeLeft} onclick={dismissNotice} />
      </span>
    </div>
  {:else if !expanded}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="pill" onmousedown={drag}>
      <Orb size={20} {mood} />
      {#if nook.working}<span class="dot working"></span>{/if}
      {#if nook.waiting}<span class="dot waiting"></span>{/if}
      <AgentDots onhover={() => open("agents")} />
    </div>
  {:else}
    <div class="panel">
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <header onmousedown={drag}>
        <Orb size={20} {mood} {ring} onpiece={(id) => { select("nook"); nook.select(id); }} />
        <nav>
          <button class:on={shown === "nook"} onclick={() => select("nook")}>Nook {#if nook.waiting}<span class="dot waiting"></span>{/if}</button>
          <button class:on={shown === "agents"} onclick={() => select("agents")}>Agents {#if agents.pending}<span class="dot waiting"></span>{/if}</button>
          {#if nook.info?.capabilities.terminals}
            <button class:on={shown === "workspace"} onclick={() => select("workspace")}>Werkruimte</button>
          {/if}
          {#if playing}
            <button class:on={shown === "music"} onclick={() => select("music")}>Muziek {#if playing.playing}<span class="dot unread"></span>{/if}</button>
          {/if}
        </nav>
        <span class="spacer"></span>
        <button class="ghost icon" title="Open in venster" onclick={() => api.showMain("chat")}>⧉</button>
        <button class="ghost icon" title="Instellingen" onclick={() => api.showMain("settings")}>⚙</button>
      </header>
      <AgentAlerts
        requests={shown !== "agents"}
        left={noticeLeft}
        compact={noticeCompact}
        ondismiss={dismissNotice}
        onview={(id) => { agents.select(id); select("agents"); pinnedOpen = true; }}
      />
      <WhatsAppCard onnook={(id) => { select("nook"); pinnedOpen = true; nook.select(id); }} />
      <div class="body">
        {#if shown === "nook"}
          <div class="nooktab">
            <div class="chatcol"><Chat compact autofocus={pinnedOpen} /></div>
            <div class="side"><Today /></div>
          </div>
        {:else if shown === "agents"}
          <Agents compact />
        {:else if shown === "music" && playing}
          <Music info={playing} {since} />
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
  /* A compact notice in the bar's own row: mark and message on the left, View and the countdown OK on the right. */
  .pill.strip { justify-content: flex-start; gap: 8px; padding: 0 4px 0 14px; }
  .strip .message { flex: 1; min-width: 0; font-size: 12px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .stripbuttons { display: flex; align-items: center; gap: 4px; flex: none; }
  .stripbuttons .ghost { padding: 4px 10px; font-size: 12px; }
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
