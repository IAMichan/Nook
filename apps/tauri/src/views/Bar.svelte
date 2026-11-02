<script lang="ts">
  // De balk bovenaan het scherm: in rust een pil met Nook, open een paneel met de tabs Home, Nook, Agents en Werkruimte.
  import { untrack } from "svelte";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { LogicalPosition, LogicalSize } from "@tauri-apps/api/dpi";
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import Orb from "../components/Orb.svelte";
  import Icon from "../components/Icon.svelte";
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
  import { tr, english } from "../lib/i18n.svelte";
  import { heard } from "../components/Orb.svelte";
  import AgentAlerts from "./agents/AgentAlerts.svelte";
  import NoticeMark from "../components/NoticeMark.svelte";
  import NoticeOk from "../components/NoticeOk.svelte";
  import { compactNotice, Countdown, noticeTone } from "../lib/notice";
  import WhatsAppCard from "./connectors/WhatsAppCard.svelte";
  import { whatsapp } from "../lib/whatsapp.svelte";
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

  const mood = $derived(nook.waiting ? "waiting" : nook.working ? "working" : "idle");
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
    if (resizing || pinnedOpen || nook.busy || agents.pending || agents.attention || whatsapp.chat) return;
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

  // One click flips the interface and Nook's answers between Dutch and English.
  function toggleLanguage() {
    const next = english() ? "nl" : "en";
    nook.saveSettings({ appLanguage: next, language: next });
  }

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

  // WhatsApp: a new message opens the bar with its card, which stays until you answer or close it.
  $effect(() => {
    whatsapp.start();
  });
  $effect(() => {
    if (whatsapp.chat && !untrack(() => expanded) && !untrack(() => quiet.silent)) untrack(() => open());
  });

  // Escape first shrinks an enlarged photo, then closes the WhatsApp card, then the bar.
  function escape() {
    if (whatsapp.enlarged) whatsapp.enlarged = null;
    else if (whatsapp.chat) whatsapp.dismiss();
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

<svelte:window onkeydown={(e) => e.key === "Escape" && escape()} onblur={() => !barDraft.picking && !resizing && Date.now() - openedAt > 600 && close()} onfocus={() => setTimeout(() => (barDraft.picking = false), 300)} />

<div class="bar" class:expanded class:floating role="region" onmouseenter={() => (inside = true)} onmouseleave={leave}>
  {#if !expanded && strip && agents.attention}
    {@const card = agents.attention}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="pill strip" onmousedown={drag}>
      <NoticeMark tone={noticeTone(card.status)} size={card.status === "done" || card.status === "failed" ? 13 : 15} />
      <span class="message">{compactNotice(card.name, card.project, card.status, english())}</span>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span class="stripbuttons" onmousedown={(e) => e.stopPropagation()}>
        <button class="ghost" onclick={() => viewNotice(card.id)}>{tr("Bekijk", "View")}</button>
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
    </div>
  {:else}
    <div class="panel">
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <header onmousedown={drag}>
        <Orb size={20} {mood} {ring} onpiece={(id) => { select("nook"); nook.select(id); }} />
        <nav>
          <button class:on={shown === "home"} onclick={() => select("home")}>Home</button>
          <button class:on={shown === "nook"} onclick={() => select("nook")}>Nook {#if nook.waiting}<span class="dot waiting"></span>{/if}</button>
          <button class:on={shown === "chats"} onclick={() => select("chats")}>{tr("Chats", "Chats")}</button>
          <button class:on={shown === "agents"} onclick={() => select("agents")}>Agents {#if agents.pending}<span class="dot waiting"></span>{/if}</button>
          {#if nook.info?.capabilities.terminals}
            <button class:on={shown === "workspace"} onclick={() => select("workspace")}>{tr("Werkruimte", "Workspace")}</button>
          {/if}
          <button class:on={shown === "commands"} onclick={() => select("commands")}>{tr("Commando's", "Commands")}</button>
          {#if playing}
            <button class:on={shown === "music"} onclick={() => select("music")}>{tr("Muziek", "Music")} {#if playing.playing}<span class="dot unread"></span>{/if}</button>
          {/if}
        </nav>
        <span class="spacer"></span>
        <button class="ghost icon lang" title={tr("Taal: klik voor English", "Language: click for Nederlands")} onclick={toggleLanguage}>{english() ? "EN" : "NL"}</button>
        <button class="ghost icon lock" class:on={locked} title={locked ? tr("Vergrendeld: klik om te ontgrendelen", "Locked: click to unlock") : tr("Houd Nook open als je wegklikt", "Keep Nook open when you click away")} onclick={() => { locked = !locked; if (locked) pinnedOpen = true; }}><Icon name={locked ? "lock" : "unlock"} size={14} /></button>
        <button class="ghost icon" title={tr("Open in venster", "Open in window")} onclick={() => api.showMain("chat")}>⧉</button>
        <button class="ghost icon" title={tr("Instellingen", "Settings")} onclick={() => api.showMain("settings")}>⚙</button>
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
        <div class="grip {g}" onpointerdown={(e) => resize(e, g)}></div>
      {/each}
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
  /* The closed bar is a small round Nook with a thick black rim, so it stays out of the way of the browser's tabs. */
  .pill.round {
    position: relative;
    box-sizing: border-box;
    border: 3px solid #000;
    border-radius: 50%;
    gap: 0;
    overflow: hidden;
    cursor: pointer;
    transition: box-shadow 0.25s ease;
  }
  .pill.round:hover { box-shadow: inset 0 0 0 2px color-mix(in srgb, var(--paper) 35%, transparent); }
  .pill.round:active .orbwrap { transform: scale(0.88); }
  .orbwrap { display: flex; transition: transform 0.15s ease; }
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
    color: #fff;
    font-size: 9px;
    font-weight: 700;
    line-height: 14px;
    text-align: center;
    pointer-events: none;
  }
  @media (prefers-reduced-motion: reduce) {
    .pill.round.dropping::after, .pill.round.swallowed .orbwrap { animation: none; }
  }
  .dot.corner { position: absolute; top: 3px; right: 3px; }
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
    position: relative;
  }
  .grip { position: absolute; z-index: 5; touch-action: none; }
  .grip.left, .grip.right { top: 12px; bottom: 12px; width: 8px; cursor: ew-resize; }
  .grip.left { left: 0; }
  .grip.right { right: 0; }
  .grip.bottom { left: 12px; right: 12px; bottom: 0; height: 8px; cursor: ns-resize; }
  .grip.bottom-left, .grip.bottom-right { bottom: 0; width: 16px; height: 16px; }
  .grip.bottom-left { left: 0; cursor: nesw-resize; }
  .grip.bottom-right { right: 0; cursor: nwse-resize; }
  .floating .panel { border-radius: 22px; }
  @keyframes drop { from { transform: scaleY(0.7); opacity: 0; } }
  header { display: flex; align-items: center; gap: 10px; padding: 10px 12px 6px; }
  nav { display: flex; gap: 4px; }
  nav button { background: transparent; border: none; color: var(--text2); border-radius: 999px; padding: 5px 12px; display: flex; gap: 6px; align-items: center; }
  nav button.on { background: var(--smoke); color: var(--paper); }
  .spacer { flex: 1; }
  .icon { padding: 4px 8px; }
  .icon.lang { font-size: 11px; font-weight: 700; letter-spacing: 0.04em; }
  .icon.lock.on { color: var(--iris); }
  .body { flex: 1; min-height: 0; }
  .nooktab { display: grid; grid-template-columns: 1fr 220px; height: 100%; }
  .chatcol { min-height: 0; }
  .side { border-left: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; }
  .sidetabs { display: flex; gap: 2px; padding: 4px 8px 6px; }
  .sidetabs button { flex: 1; background: transparent; border: 0; color: var(--text3); border-radius: 999px; padding: 3px 8px; font-size: 11px; }
  .sidetabs button.on { background: var(--smoke); color: var(--paper); }
  .sidebody { flex: 1; min-height: 0; overflow-y: auto; }
  .panel :global(.composer) { background: var(--notch); }
</style>
