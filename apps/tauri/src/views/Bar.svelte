<script lang="ts">
  // De balk bovenaan het scherm: in rust een pil met Nook, open een paneel met de tabs Home, Nook, Agents en Werkruimte.
  import { tick, untrack } from "svelte";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { LogicalPosition, LogicalSize } from "@tauri-apps/api/dpi";
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import Orb from "../components/Orb.svelte";
  import Icon from "../components/Icon.svelte";
  import Ico from "../components/ui/Ico.svelte";
  import AgentMark from "./companion/ui/AgentMark.svelte";
  import Today from "./Today.svelte";
  import Agents from "./Agents.svelte";
  import Workspace from "./Workspace.svelte";
  import Music from "./services/Music.svelte";
  import Commands from "./Commands.svelte";
  import NookHistory from "./NookHistory.svelte";
  import Chats from "./Chats.svelte";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import { listening } from "../lib/listening.svelte";
  import { attachments } from "../lib/attachments.svelte";
  import { play } from "../lib/sounds";
  import { agents } from "../lib/agents.svelte";
  import { quiet } from "../lib/quiet.svelte";
  import { barDraft } from "../lib/draft.svelte";
  import { tr, english, appLanguage, APP_LANGUAGES } from "../lib/i18n.svelte";
  import { heard } from "../components/Orb.svelte";
  import AgentAlerts from "./agents/AgentAlerts.svelte";
  import NoticeMark from "../components/NoticeMark.svelte";
  import NoticeOk from "../components/NoticeOk.svelte";
  import { compactNotice, Countdown, noticeTone } from "../lib/notice";
  import { TRACK_STRIP_MS, isNewTrack, orbMood, trackLine } from "../lib/bar-music";
  import WhatsAppCard from "./connectors/WhatsAppCard.svelte";
  import { whatsapp } from "../lib/whatsapp.svelte";
  import ChatArrivedCard from "../components/ChatArrivedCard.svelte";
  import { arrivedChat, showChat } from "../lib/chat-arrived.svelte";
  import Home from "./home/Home.svelte";
  import type { Target } from "../lib/inbox";

  type Tab = "home" | "nook" | "chats" | "agents" | "workspace" | "music" | "commands";
  let expanded = $state(false);
  let tab = $state<Tab>(firstTab());

  /// The remembered tab; Home the first time, also for someone who used the bar before Home existed.
  function firstTab(): Tab {
    try {
      if (!localStorage.getItem("bar.homeShown")) {
        localStorage.setItem("bar.homeShown", "1");
        localStorage.setItem("bar.tab", "home");
      }
      return (localStorage.getItem("bar.tab") as Tab) || "home";
    } catch {
      return "home";
    }
  }
  let pinnedOpen = $state(false);
  let locked = $state(false);
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  let inside = $state(false);
  let openedAt = 0;
  // Agent notices: a compact one widens the closed bar (`strip`); a detailed one opens the panel. `noticeLeft` is what
  // is left of its countdown, for the ring on OK.
  let strip = $state(false);
  let openedForNotice = false;
  let noticeLeft = $state<number | null>(null);
  const noticeCompact = $derived(nook.settings?.agentNotice === "compact");

  const floating = $derived(nook.settings?.placement === "floating");

  async function open(focus?: string) {
    clearTimeout(closeTimer);
    const wasExpanded = expanded;
    if (!expanded) {
      strip = false;
      expanded = true;
      // Resizing and focusing the window can fire a blur of its own; that must not close the panel that is opening.
      openedAt = Date.now();
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
    } else if (focus === "music") {
      tab = "music";
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
  // Closed, Nook shows everything that waits or works; open, the mood of the tab on screen (UI-55, `orbMood`).
  const moodInputs = $derived({
    nookWaiting: nook.waiting, nookWorking: nook.working, agentsWaiting: agents.pending,
    agentsRunning: agents.sessions.filter((s) => s.status === "running").length, playing: !!playing?.playing,
  });
  const mood = $derived(orbMood(null, moodInputs));
  const tabMood = $derived(orbMood(shown, moodInputs));
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

  // The tray tooltip says how many Nooks wait on you (only the bar reports it, so it is said once).
  $effect(() => {
    api.trayStatus(nook.waiting, nook.working).catch(() => {});
  });

  // De ring om Nook in het open paneel: alles waar hij mee bezig is of wat op je wacht.
  const ring = $derived(
    nook.nooks
      .filter((n) => n.status === "working" || n.status === "waiting")
      .map((n) => ({ id: n.id, label: n.title, state: n.status as "working" | "waiting" })),
  );

  // Locked, the panel ignores a click elsewhere and a lost focus (handy while dragging attachments in from another window); only Esc closes it.
  async function close(force = false) {
    if (!expanded || (locked && !force)) return;
    expanded = false;
    pinnedOpen = false;
    locked = false;
    await api.barExpand(false);
    services.asideShow();
  }

  function leave() {
    inside = false;
    // A notice closes the bar itself, once its countdown has run out with the pointer off the bar.
    if (resizing || pinnedOpen || nook.busy || agents.pending || agents.attention || whatsapp.chat || arrivedChat.thread) return;
    // Both the pointer and a notice that ran out call this; a second timer must not orphan the first.
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => close(), 450);
  }

  // The closed bar only opens on a click; it then stays open until Esc, a click elsewhere or the window loses focus.
  async function openByClick() {
    pinnedOpen = true;
    await open();
  }

  // A file dragged onto the closed round Nook: he looks up while it hovers, swallows it on the drop, and then the panel
  // opens with the file in the field. (The bar's webview has the native drag-drop handler off, so these are web events.)
  let dropping = $state(false);
  let swallowed = $state(false);
  let dragDepth = 0;
  const hasFiles = (e: DragEvent) => e.dataTransfer?.types.includes("Files") ?? false;

  function dragEnter(e: DragEvent) {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth++;
    dropping = true;
  }

  function dragOver(e: DragEvent) {
    if (!hasFiles(e)) return;
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
  }

  function dragLeave() {
    dragDepth = Math.max(0, dragDepth - 1);
    if (!dragDepth) dropping = false;
  }

  async function drop(e: DragEvent) {
    e.preventDefault();
    dragDepth = 0;
    dropping = false;
    const files = e.dataTransfer?.files;
    if (!files?.length) return;
    swallowed = true;
    heard();
    const reading = barDraft.addFiles(files);
    await new Promise((r) => setTimeout(r, 520));
    swallowed = false;
    await openByClick();
    await reading;
  }

  // One click moves the interface (and Nook's answers, unless they follow the question) to the next language.
  function toggleLanguage() {
    const codes = APP_LANGUAGES.map((l) => l.code);
    const next = codes[(codes.indexOf(appLanguage()) + 1) % codes.length];
    nook.saveSettings(nook.settings?.language === "auto" ? { appLanguage: next } : { appLanguage: next, language: next });
  }
  const nextLanguage = $derived(APP_LANGUAGES[(APP_LANGUAGES.findIndex((l) => l.code === appLanguage()) + 1) % APP_LANGUAGES.length].name);

  // "Laat Nook antwoorden" on a WhatsApp card: the new Nook opens in the Nook tab.
  function openNookFromCard(id: string) {
    select("nook");
    pinnedOpen = true;
    nook.select(id);
  }

  // The right-hand column of the Nook tab: the chat history (as on the Mac) or Today.
  let side = $state<"history" | "today">(localStorage.getItem("bar.side") === "today" ? "today" : "history");
  function pickSide(next: "history" | "today") {
    side = next;
    try {
      localStorage.setItem("bar.side", next);
    } catch {
      // Not remembered; the column still switches.
    }
  }

  function select(t: Tab) {
    tab = t;
    localStorage.setItem("bar.tab", t);
  }

  /// Opens what Home points at: a tab of the bar when it has one, otherwise the page in the main window.
  async function go(target: Target) {
    pinnedOpen = true;
    try {
      switch (target.kind) {
        case "route":
          if (target.route === "chat") return select("nook");
          if (target.route === "agents") return select("agents");
          if (target.route === "workspace" && nook.info?.capabilities.terminals) return select("workspace");
          return await api.showMain(target.route);
        case "settings":
          localStorage.setItem("settings.section", target.section);
          return await api.showMain("settings");
        case "workspace":
          localStorage.setItem("ws.page", target.page);
          return select("workspace");
        case "agents":
          agents.select(target.select);
          return select("agents");
        case "nook":
          select("nook");
          return await nook.select(target.id);
        case "chat":
          select("chats");
          await tick();
          return showChat(target.key);
        case "newNook":
          select("nook");
          await nook.newNook();
          if (target.ask) await nook.ask(target.ask);
          return;
      }
    } catch (e) {
      nook.error = String(e);
    }
  }

  // The window has no frame, so its own resize border is a hairline: the open panel carries its own grips on the edges
  // and corners (the top edge is where the bar hangs, so it has none).
  const grips = ["left", "right", "bottom", "bottom-left", "bottom-right"] as const;

  // The panel resizes itself: a grip captures the pointer and sets the window's size while it moves. (The system's own
  // resize drag takes the focus and mouse from the page, so the panel closed under the user's hand and left the round
  // Nook stretched over the whole window.) `resizing` also keeps a stray blur from closing the panel meanwhile.
  let resizing = $state(false);
  const MIN = { w: 480, h: 320 };

  // The outermost pixels of the window belong to the system's own resize border, which sits outside the page, so a
  // drag there takes the focus before any grip sees it. Such a drag is told apart by the window resizing right after
  // the blur: the close waits a moment and is dropped when the size changes or the focus comes back meanwhile.
  let lastResize = 0;
  $effect(() => {
    const off = getCurrentWindow().onResized(() => (lastResize = Date.now()));
    return () => void off.then((f) => f());
  });
  function blurClose() {
    if (barDraft.picking || resizing || Date.now() - openedAt <= 600) return;
    const blurredAt = Date.now();
    setTimeout(() => {
      if (resizing || lastResize >= blurredAt - 100 || document.hasFocus()) return;
      close();
    }, 250);
  }

  function resize(e: PointerEvent, grip: (typeof grips)[number]) {
    if (e.button !== 0) return;
    e.preventDefault();
    const handle = e.currentTarget as HTMLElement;
    handle.setPointerCapture(e.pointerId);
    resizing = true;
    const start = { x: e.screenX, y: e.screenY, w: window.innerWidth, h: window.innerHeight, left: window.screenX, top: window.screenY };
    const win = getCurrentWindow();
    let frame = 0;
    let next: { w: number; h: number; left: number } | null = null;

    const apply = async () => {
      frame = 0;
      if (!next) return;
      const { w, h, left } = next;
      next = null;
      await win.setSize(new LogicalSize(w, h));
      if (grip.includes("left")) await win.setPosition(new LogicalPosition(left, start.top));
    };
    const move = (m: PointerEvent) => {
      const dx = m.screenX - start.x;
      const dy = m.screenY - start.y;
      let w = start.w;
      let h = start.h;
      if (grip.includes("right")) w = start.w + dx;
      if (grip.includes("left")) w = start.w - dx;
      if (grip.includes("bottom")) h = start.h + dy;
      w = Math.max(MIN.w, w);
      h = Math.max(MIN.h, h);
      next = { w, h, left: start.left + (start.w - w) };
      if (!frame) frame = requestAnimationFrame(apply);
    };
    const end = () => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", end);
      handle.removeEventListener("pointercancel", end);
      setTimeout(() => (resizing = false), 300);
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", end);
    handle.addEventListener("pointercancel", end);
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
    // While you share your screen or sit in a meeting and chose quiet: the Agents tab shows it, the bar does not pop open.
    if (!card || untrack(() => quiet.silent)) return;
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

  // WhatsApp: a new message never opens the bar by itself. The closed bar shows a chip under the round Nook ("Bericht
  // van Peter"); once the panel is open (by the chip or any other way) the card of that chat shows in it.
  $effect(() => {
    whatsapp.start();
  });
  $effect(() => {
    const waiting = whatsapp.pending;
    if (waiting && expanded) untrack(() => whatsapp.show(waiting.chat));
  });
  // Every other chat app does the same with its own card (`chat-arrived`, the Mac's notch chat card).
  $effect(() => {
    arrivedChat.start();
  });
  $effect(() => {
    if (arrivedChat.pending && expanded) untrack(() => arrivedChat.show());
  });
  const chipName = $derived(
    whatsapp.pending?.name ?? whatsapp.card?.conversation.name ?? arrivedChat.pending?.name ?? arrivedChat.thread?.name ?? "",
  );
  function dismissChip() {
    whatsapp.dismiss();
    arrivedChat.dismiss();
  }
  /// "Open in Nook" on a chat card: that chat in the bar's Chats tab.
  async function openArrived(key: string) {
    arrivedChat.dismiss();
    select("chats");
    pinnedOpen = true;
    await tick();
    showChat(key);
  }
  // A new track shows under the round Nook for a few seconds (the Mac's new-track strip); a message goes first.
  let trackStrip = $state<string | null>(null);
  let lastTrack: string | null | undefined = undefined;
  $effect(() => {
    const now = playing;
    let timer: ReturnType<typeof setTimeout> | undefined;
    untrack(() => {
      if (isNewTrack(lastTrack, now)) {
        trackStrip = trackLine(now);
        timer = setTimeout(() => (trackStrip = null), TRACK_STRIP_MS);
      }
      if (trackLine(now) || lastTrack === undefined) lastTrack = trackLine(now);
    });
    return () => clearTimeout(timer);
  });
  const chipVisible = $derived(!expanded && !strip && (!!chipName || !!trackStrip) && !quiet.silent);
  // "Hide Nook when idle" (Settings › General › Bar & windows): closed, without a notice or chip and with nothing working
  // or waiting, the bar hides; anything new shows it again, as do a shortcut and the tray.
  // "Nook on the bar" off (`showBar`): closed, he is out of sight altogether until a shortcut or the tray opens him.
  const idleHidden = $derived(!expanded && (nook.settings?.showBar === false || (!!nook.settings?.hideWhenIdle && !strip && !chipVisible && mood === "idle")));
  $effect(() => {
    api.barVisible(!idleHidden).catch(() => {});
  });
  // The window makes room under the round Nook while the chip shows, and goes back to the round size when it leaves.
  let chipSized = false;
  $effect(() => {
    const want = chipVisible;
    untrack(() => {
      if (want && !chipSized) {
        chipSized = true;
        api.barExpand(false, false, true);
      } else if (!want && chipSized) {
        chipSized = false;
        if (!expanded && !strip) api.barExpand(false);
      }
    });
  });

  // Escape first shrinks an enlarged photo, then closes the WhatsApp card, then the bar.
  function escape() {
    if (whatsapp.enlarged) whatsapp.enlarged = null;
    else if (whatsapp.chat) whatsapp.dismiss();
    else if (arrivedChat.thread) arrivedChat.dismiss();
    else {
      if (agents.attention) dismissNotice();
      close(true);
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

<svelte:window onkeydown={(e) => e.key === "Escape" && escape()} onblur={blurClose} onfocus={() => setTimeout(() => (barDraft.picking = false), 300)} />

<div class="bar" class:expanded class:floating class:hasChip={chipVisible} role="region" onmouseenter={() => (inside = true)} onmouseleave={leave}>
  {#if !expanded && strip && agents.attention}
    {@const card = agents.attention}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="pill strip" onmousedown={drag}>
      <span class="strip-mark">
        {#if card.name}
          <AgentMark agent={card.name} size={16} />
          <span class="strip-badge {noticeTone(card.status)}"></span>
        {:else}
          <NoticeMark tone={noticeTone(card.status)} size={card.status === "done" || card.status === "failed" ? 13 : 15} />
        {/if}
      </span>
      <span class="message">{compactNotice(card.name, card.project, card.status)}</span>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="stripbuttons" onmousedown={(e) => e.stopPropagation()}>
        <span class="strip-action-bar">
          <button class="strip-action" onclick={() => viewNotice(card.id)}>{tr("Bekijk", "View")}</button>
        </span>
        <NoticeOk compact left={noticeLeft} onclick={dismissNotice} />
      </span>
    </div>
  {:else if !expanded}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      class="pill round"
      class:dropping
      class:swallowed
      role="button"
      tabindex="0"
      title={barDraft.files ? tr("Open Nook (er wachten bestanden)", "Open Nook (files waiting)") : tr("Open Nook, of sleep een bestand op mij", "Open Nook, or drop a file on me")}
      onmousedown={drag}
      onclick={openByClick}
      onkeydown={(e) => (e.key === "Enter" || e.key === " ") && openByClick()}
      ondragenter={dragEnter}
      ondragover={dragOver}
      ondragleave={dragLeave}
      ondrop={drop}
    >
      <span class="orbwrap"><Orb size={26} mood={dropping ? "seen" : mood} /></span>
      {#if barDraft.files}<span class="badge">{barDraft.files}</span>{/if}
      {#if nook.working}<span class="dot working corner"></span>{/if}
      {#if nook.waiting}<span class="dot waiting corner"></span>{/if}
      {#if playing?.playing && !nook.working && !nook.waiting}<span class="eq corner-eq playing" aria-hidden="true"><i></i><i></i><i></i></span>{/if}
    </div>
    {#if chipVisible && !chipName && trackStrip}
      <div class="chip track" role="status">
        <button class="chiptext" title={trackStrip} onclick={() => { trackStrip = null; open("music"); }}>
          <span class="eq" class:playing={playing?.playing} aria-hidden="true"><i></i><i></i><i></i></span><span class="chiplabel">{trackStrip}</span>
        </button>
        <button class="chipclose" title={tr("Sluiten", "Dismiss")} aria-label={tr("Sluiten", "Dismiss")} onclick={() => (trackStrip = null)}><Ico name="x" size={12} stroke={2.4} /></button>
      </div>
    {:else if chipVisible}
      <div class="chip">
        <button class="chiptext" title={tr("Open Nook", "Open Nook")} onclick={openByClick}>
          <span class="chipico"><Ico name="message-circle" size={12} stroke={2.2} /></span><span class="chiplabel">{tr("Bericht van {name}", "Message from {name}", { name: chipName })}</span>
        </button>
        <button class="chipclose" title={tr("Sluiten", "Dismiss")} aria-label={tr("Sluiten", "Dismiss")} onclick={dismissChip}><Ico name="x" size={12} stroke={2.4} /></button>
      </div>
    {/if}
  {:else}
    <div class="panel">
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <header onmousedown={drag}>
        <div class="header-left">
          <button class="orb-home" title={tr("Naar Nook", "Go to Nook")} aria-label={tr("Naar Nook", "Go to Nook")} onclick={() => select("nook")}>
            <Orb size={30} mood={tabMood} {ring} onpiece={(id) => { select("nook"); nook.select(id); }} />
          </button>
        </div>
        <div class="header-capsule" onmousedown={(e) => e.stopPropagation()}>
          <nav aria-label={tr("Hoofdnavigatie", "Main navigation")}>
            <button class:on={shown === "home"} onclick={() => select("home")}>Home</button>
            <button class:on={shown === "nook"} onclick={() => select("nook")}>
              <span>Nook</span>{#if nook.waiting}<span class="tab-dot waiting"></span>{/if}
            </button>
            <button class:on={shown === "chats"} onclick={() => select("chats")}>{tr("Chats", "Chats")}</button>
            <button class:on={shown === "agents"} onclick={() => select("agents")}>
              <span>{tr("Agents", "Agents")}</span>{#if agents.pending}<span class="tab-count">{agents.pending}</span>{/if}
            </button>
            {#if nook.info?.capabilities.terminals}
              <button class:on={shown === "workspace"} onclick={() => select("workspace")}>{tr("Werkruimte", "Workspace")}</button>
            {/if}
            <button class:on={shown === "commands"} onclick={() => select("commands")}>{tr("Commando's", "Commands")}</button>
            {#if playing}
              <button class:on={shown === "music"} onclick={() => select("music")}>
                <span>{tr("Muziek", "Music")}</span>{#if playing.playing}<span class="tab-dot music"></span>{/if}
              </button>
            {/if}
          </nav>
          <span class="capsule-divider" aria-hidden="true"></span>
          <button class="cap-btn" title={tr("Praat met Nook", "Talk to Nook")} aria-label={tr("Praat met Nook", "Talk to Nook")} onclick={() => open("voice")}>
            <Ico name="mic" size={14} stroke={2} />
          </button>
        </div>
        <div class="header-right" onmousedown={(e) => e.stopPropagation()}>
          <button class="bar-btn lang" title={tr("Taal: klik voor {next}", "Language: click for {next}", { next: nextLanguage })} onclick={toggleLanguage}>{appLanguage().toUpperCase()}</button>
          <button class="bar-btn lock" class:on={locked} title={locked ? tr("Vergrendeld: klik om te ontgrendelen", "Locked: click to unlock") : tr("Houd Nook open als je wegklikt", "Keep Nook open when you click away")} aria-label={locked ? tr("Vergrendeld: klik om te ontgrendelen", "Locked: click to unlock") : tr("Houd Nook open als je wegklikt", "Keep Nook open when you click away")} onclick={() => { locked = !locked; if (locked) pinnedOpen = true; }}><Icon name={locked ? "lock" : "unlock"} size={14} /></button>
          <button class="bar-btn" title={tr("Verder in het venster (dit gesprek)", "Continue in the window (this conversation)")} aria-label={tr("Verder in het venster (dit gesprek)", "Continue in the window (this conversation)")} onclick={() => api.showMain(nook.activeId ? `nook:${nook.activeId}` : "chat")}><Ico name="app-window-mac" size={14} stroke={1.9} /></button>
          <button class="bar-btn" title={tr("Instellingen", "Settings")} aria-label={tr("Instellingen", "Settings")} onclick={() => api.showMain("settings")}><Icon name="settings" size={14} /></button>
          <button class="bar-btn" title={tr("Sluiten", "Close")} aria-label={tr("Sluiten", "Close")} onclick={() => close(true)}><Ico name="x" size={15} stroke={2} /></button>
        </div>
      </header>
      <AgentAlerts
        requests={shown !== "agents"}
        left={noticeLeft}
        compact={noticeCompact}
        ondismiss={dismissNotice}
        onview={(id) => { agents.select(id); select("agents"); pinnedOpen = true; }}
      />
      {#if shown !== "chats"}
        <WhatsAppCard onnook={openNookFromCard} />
        <ChatArrivedCard onopen={openArrived} />
      {/if}
      <div class="body">
        {#if shown === "home"}
          <Home compact onopen={go} />
        {:else if shown === "nook"}
          <div class="nooktab">
            <div class="chatcol"><Chat compact autofocus={pinnedOpen} /></div>
            <div class="side">
              <div class="sidetabs" role="tablist">
                <button role="tab" aria-selected={side === "history"} class:on={side === "history"} onclick={() => pickSide("history")}>{tr("Geschiedenis", "History")}</button>
                <button role="tab" aria-selected={side === "today"} class:on={side === "today"} onclick={() => pickSide("today")}>{tr("Vandaag", "Today")}</button>
              </div>
              <div class="sidebody">{#if side === "history"}<NookHistory />{:else}<Today />{/if}</div>
            </div>
          </div>
        {:else if shown === "chats"}
          <Chats onnook={openNookFromCard} />
        {:else if shown === "agents"}
          <Agents compact />
        {:else if shown === "commands"}
          <Commands onuse={(text) => { barDraft.text = text; select("nook"); pinnedOpen = true; }} />
        {:else if shown === "music" && playing}
          <Music info={playing} {since} />
        {:else}
          <Workspace compact />
        {/if}
      </div>
      {#each grips as g (g)}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div class="grip {g}" onpointerdown={(e) => resize(e, g)}>
          {#if g === "bottom-left"}
            <svg class="corner-mark" viewBox="0 0 10 10" width="10" height="10" aria-hidden="true">
              <path d="M1 1 L9 9 M1 5.5 L4.5 9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none" />
            </svg>
          {:else if g === "bottom-right"}
            <svg class="corner-mark" viewBox="0 0 10 10" width="10" height="10" aria-hidden="true">
              <path d="M9 1 L1 9 M9 5.5 L5.5 9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none" />
            </svg>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .bar { width: 100vw; height: 100vh; display: flex; justify-content: center; align-items: flex-start; }
  .bar.hasChip { flex-direction: column; align-items: center; gap: var(--space-6); }
  .bar.hasChip .pill.round { width: 44px; height: 44px; flex: none; }

  /* The arrival chip under the closed round Nook: who wrote or what plays, one click opens Nook. */
  .chip {
    display: flex;
    align-items: center;
    max-width: 100%;
    box-sizing: border-box;
    height: 30px;
    background: var(--notch);
    border: 1px solid color-mix(in srgb, var(--paper) 14%, transparent);
    border-radius: 999px;
    box-shadow: var(--shadow-popover);
    overflow: hidden;
    animation: drop var(--motion-reveal);
  }
  .chip button { background: transparent; border: 0; color: var(--paper); font: var(--text-detail); font-weight: 500; cursor: pointer; }
  .chiptext { display: inline-flex; align-items: center; gap: var(--space-6); padding: 0 var(--space-6) 0 var(--space-12); height: 100%; min-width: 0; }
  .chipico { display: inline-flex; color: var(--text2); flex: none; }
  .chiplabel { min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .chipclose { display: grid; place-items: center; padding: 0 var(--space-8) 0 var(--space-4); height: 100%; color: var(--text3); transition: color var(--motion-quick); }
  .chipclose:hover { color: var(--paper); }

  /* The equalizer while music plays (the notch's level bars): three bars in the music tone, still when paused. */
  .eq { display: inline-flex; align-items: flex-end; gap: 2px; height: 10px; flex: none; }
  .eq i { display: block; width: 2px; height: 100%; background: var(--music); border-radius: 999px; transform-origin: bottom; transform: scaleY(0.4); }
  .eq.playing i { animation: level 0.9s ease-in-out infinite alternate; }
  .eq.playing i:nth-child(2) { animation-delay: -0.3s; animation-duration: 0.7s; }
  .eq.playing i:nth-child(3) { animation-delay: -0.6s; animation-duration: 1.1s; }
  @keyframes level { from { transform: scaleY(0.25); } to { transform: scaleY(1); } }
  .corner-eq { position: absolute; right: 5px; bottom: 6px; margin: 0; height: 8px; }
  @media (prefers-reduced-motion: reduce) { .eq.playing i { animation: none; transform: scaleY(0.7); } }

  .pill {
    height: 100%;
    width: 100%;
    background: var(--notch);
    border-radius: 0 0 var(--radius-composer) var(--radius-composer);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-8);
    cursor: default;
  }
  .floating .pill { border-radius: 999px; border: 1px solid color-mix(in srgb, var(--paper) 12%, transparent); box-sizing: border-box; cursor: grab; }
  /* The closed bar is a small round Nook with a hairline rim, so it reads cleanly against any desktop. */
  .pill.round {
    position: relative;
    box-sizing: border-box;
    border: 1px solid color-mix(in srgb, var(--paper) 12%, transparent);
    border-radius: 50%;
    gap: 0;
    overflow: hidden;
    cursor: pointer;
    transition: box-shadow var(--motion-hover), border-color var(--motion-hover);
  }
  .pill.round:hover {
    border-color: color-mix(in srgb, var(--paper) 28%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--paper) 18%, transparent);
  }
  .pill.round:active .orbwrap { transform: scale(0.88); }
  .orbwrap { display: flex; transition: transform var(--motion-quick); }
  /* Hovering the closed bar: a small hop, as if Nook noticed you. */
  .pill.round:hover .orbwrap { animation: hop 0.7s cubic-bezier(0.3, 1.5, 0.5, 1); }
  @keyframes hop {
    0% { transform: translateY(0) scale(1); }
    30% { transform: translateY(-4px) scale(1.18); }
    60% { transform: translateY(1px) scale(0.94); }
    100% { transform: translateY(0) scale(1.06); }
  }
  @media (prefers-reduced-motion: reduce) { .pill.round:hover .orbwrap { animation: none; } }
  /* A file over Nook: the rim lights up, a dashed ring turns around him and he leans in. */
  .pill.round.dropping { box-shadow: 0 0 0 3px var(--iris), 0 0 18px color-mix(in srgb, var(--iris) 60%, transparent); }
  .pill.round.dropping::after {
    content: "";
    position: absolute;
    inset: 2px;
    border-radius: 50%;
    border: 2px dashed var(--iris);
    animation: spin 2.4s linear infinite;
    pointer-events: none;
  }
  .pill.round.dropping .orbwrap { transform: scale(1.22) translateY(-1px); }
  @keyframes spin { to { transform: rotate(360deg); } }
  /* The drop: a gulp (squash, then a happy bounce). */
  .pill.round.swallowed .orbwrap { animation: gulp 0.52s cubic-bezier(0.3, 1.4, 0.5, 1); }
  @keyframes gulp {
    0% { transform: scale(1.22); }
    35% { transform: scale(0.7, 1.15); }
    65% { transform: scale(1.18, 0.86); }
    100% { transform: scale(1); }
  }
  /* How many files are waiting in the field of the closed bar. */
  .badge {
    position: absolute;
    bottom: 1px;
    right: 1px;
    min-width: 14px;
    height: 14px;
    padding: 0 3px;
    box-sizing: border-box;
    border-radius: 999px;
    background: var(--iris);
    color: var(--on-iris);
    font: var(--text-caption);
    font-weight: 700;
    line-height: 14px;
    text-align: center;
    pointer-events: none;
  }
  @media (prefers-reduced-motion: reduce) {
    .pill.round.dropping::after, .pill.round.swallowed .orbwrap { animation: none; }
  }
  .dot.corner { position: absolute; top: 3px; right: 3px; }

  /* A compact agent notice in the bar's own row (`inlineDoneStrip` + `NookNoticeEnd`): agent logo and message on the
     left, dark action pill and countdown OK on the right. */
  .pill.strip { justify-content: flex-start; gap: var(--space-8); padding: 0 var(--space-8) 0 var(--space-12); }
  .strip-mark { position: relative; flex: none; display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; }
  .strip-badge { position: absolute; right: -2px; bottom: -2px; width: 7px; height: 7px; border-radius: 999px; border: 1.5px solid var(--notch); background: var(--mint); }
  .strip-badge.waiting { background: var(--amber); }
  .strip-badge.failed { background: var(--coral); }
  .strip .message { flex: 1; min-width: 0; font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .stripbuttons { display: flex; align-items: center; gap: var(--space-6); flex: none; }
  .strip-action-bar { display: inline-flex; align-items: center; height: 26px; padding: 0 var(--space-2); background: var(--graphite); border: 1px solid var(--line2); border-radius: 999px; }
  .strip-action { height: 22px; padding: 0 var(--space-8); border: 0; border-radius: 999px; background: transparent; color: var(--paper); font: var(--text-detail); font-weight: 500; cursor: pointer; }
  .strip-action:hover { background: var(--smoke); }

  /* Open panel (`NotchRootView` + `PanelView`): true-black shape with notch corners, hairline edge when floating. */
  .panel {
    width: 100%;
    height: 100%;
    box-sizing: border-box;
    background: var(--notch);
    border-radius: 0 0 var(--radius-pill) var(--radius-pill);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    animation: drop var(--motion-panel);
    transform-origin: top center;
    position: relative;
  }
  .floating .panel {
    border-radius: var(--radius-pill);
    border: 1px solid color-mix(in srgb, var(--paper) 10%, transparent);
    box-shadow: var(--shadow-popover);
  }
  @keyframes drop { from { transform: scaleY(0.7); opacity: 0; } }

  /* Header (`PanelView.header` + `headerCapsule`): Nook orb left, centered floating surface capsule, quiet controls right. */
  header {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-12) var(--space-16) var(--space-8);
    flex: none;
  }
  .header-left { display: flex; align-items: center; justify-content: flex-start; min-width: 0; }
  .orb-home {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: 0;
    background: transparent;
    cursor: pointer;
    border-radius: 999px;
  }
  .header-capsule {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-4);
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: var(--radius-panel);
    min-width: 0;
  }
  nav { display: flex; align-items: center; gap: var(--space-2); }
  nav button {
    background: transparent;
    border: 0;
    color: var(--text3);
    border-radius: var(--radius-control);
    padding: 5px 10px;
    font: var(--text-control);
    display: inline-flex;
    gap: var(--space-6);
    align-items: center;
    cursor: pointer;
    white-space: nowrap;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  nav button:hover:not(.on) { color: var(--paper); }
  nav button.on { background: var(--smoke); color: var(--paper); }
  .tab-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 16px;
    height: 16px;
    padding: 0 var(--space-4);
    border-radius: var(--radius-chip);
    background: color-mix(in srgb, var(--amber) 14%, transparent);
    color: var(--amber);
    font: var(--text-caption);
    font-weight: 600;
  }
  .tab-dot { width: 5px; height: 5px; border-radius: 999px; flex: none; }
  .tab-dot.waiting { background: var(--amber); }
  .tab-dot.music { background: var(--music); }
  .capsule-divider { width: 1px; height: 18px; background: var(--border); margin: 0 var(--space-4); flex: none; }
  .cap-btn {
    display: grid;
    place-items: center;
    width: 30px;
    height: 30px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .cap-btn:hover { background: var(--smoke); color: var(--paper); }

  .header-right { display: flex; align-items: center; justify-content: flex-end; gap: var(--space-2); }
  .bar-btn {
    display: grid;
    place-items: center;
    min-width: 30px;
    height: 30px;
    padding: 0 var(--space-4);
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .bar-btn:hover { background: var(--smoke); color: var(--paper); }
  .bar-btn.lang { font: var(--text-caption); font-weight: 600; letter-spacing: 0.04em; padding: 0 var(--space-6); }
  .bar-btn.lock.on { color: var(--iris); background: color-mix(in srgb, var(--iris) 12%, transparent); }

  /* Harmonize AgentAlerts notice cards inside the bar panel with the Mac's notch card tone and spacing. */
  .panel :global(.alert) { padding: var(--space-4) var(--space-16) var(--space-8); }
  .panel :global(.alert .status) {
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: var(--radius-panel);
    padding: var(--space-12) var(--space-16);
    gap: var(--space-8);
  }
  .panel :global(.alert .status .context) { font: var(--text-label); color: var(--text2); gap: var(--space-6); }
  .panel :global(.alert .status .headline) { color: var(--text2); font-weight: 500; }
  .panel :global(.alert .status .lines) { margin-left: auto; font: var(--text-caption); font-family: var(--mono); }
  .panel :global(.alert .status .title) { font: var(--text-title); color: var(--paper); }
  .panel :global(.alert .status .actions) { background: var(--graphite); border-color: var(--line2); }

  .body { flex: 1; min-height: 0; }
  .nooktab { display: grid; grid-template-columns: 1fr 220px; height: 100%; }
  .chatcol { min-height: 0; }
  .side { border-left: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; }
  .sidetabs { display: flex; gap: var(--space-2); padding: var(--space-4) var(--space-8) var(--space-6); }
  .sidetabs button { flex: 1; background: transparent; border: 0; color: var(--text3); border-radius: var(--radius-control); padding: var(--space-4) var(--space-8); font: var(--text-label); cursor: pointer; }
  .sidetabs button.on { background: var(--smoke); color: var(--paper); }
  .sidebody { flex: 1; min-height: 0; overflow-y: auto; }
  .panel :global(.composer) { background: var(--notch); }

  /* Resize handles (`NotchResizeHandles`): faint diagonal marks in bottom corners, subtle edge bar on hover. */
  .grip { position: absolute; z-index: 5; touch-action: none; }
  .grip.left, .grip.right { top: 16px; bottom: 24px; width: 10px; cursor: ew-resize; display: flex; align-items: center; justify-content: center; }
  .grip.left { left: 0; }
  .grip.right { right: 0; }
  .grip.left::after, .grip.right::after { content: ""; width: 3px; height: 44px; border-radius: 999px; background: transparent; transition: background var(--motion-hover); }
  .grip.left:hover::after, .grip.right:hover::after { background: color-mix(in srgb, var(--paper) 45%, transparent); }
  .grip.bottom { left: 24px; right: 24px; bottom: 0; height: 10px; cursor: ns-resize; display: flex; align-items: center; justify-content: center; }
  .grip.bottom::after { content: ""; width: 44px; height: 3px; border-radius: 999px; background: transparent; transition: background var(--motion-hover); }
  .grip.bottom:hover::after { background: color-mix(in srgb, var(--paper) 45%, transparent); }
  .grip.bottom-left, .grip.bottom-right { bottom: 0; width: 24px; height: 24px; display: flex; align-items: flex-end; color: color-mix(in srgb, var(--paper) 18%, transparent); transition: color var(--motion-hover); }
  .grip.bottom-left { left: 0; justify-content: flex-start; padding: 0 0 8px 8px; box-sizing: border-box; cursor: nesw-resize; }
  .grip.bottom-right { right: 0; justify-content: flex-end; padding: 0 8px 8px 0; box-sizing: border-box; cursor: nwse-resize; }
  .grip.bottom-left:hover, .grip.bottom-right:hover { color: color-mix(in srgb, var(--paper) 70%, transparent); }
  .corner-mark { pointer-events: none; display: block; }
</style>
