<script lang="ts">
  // Het hoofdvenster (en de hele app op Android): Chat met al je Nooks, Agents, Werkruimte en Instellingen.
  import { tick, untrack } from "svelte";
  import { api, events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import Chat from "../components/Chat.svelte";
  import ChatTerminalPanel from "../components/ChatTerminalPanel.svelte";
  import Chats from "./Chats.svelte";
  import NookList from "../components/NookList.svelte";
  import Ico from "../components/ui/Ico.svelte";
  import StatusPill from "../components/ui/StatusPill.svelte";
  import PullGlyph from "./agents/pulls/PullGlyph.svelte";
  import Icon from "../components/Icon.svelte";
  import CommandPalette from "../components/CommandPalette.svelte";
  import { conversationMarkdown } from "../lib/conversation-export";
  import { toast } from "../lib/toast.svelte";
  import LazyView from "../components/LazyView.svelte";
  import { LEAVE_SETTINGS, parseRoute, reloadRoute, resumeRoute, routeTitles, routeViews, type Route } from "../lib/shell-routes";
  import { FOCUS_AREAS, nextArea, shellShortcut } from "../lib/shell-shortcuts";
  import CheatSheet from "../components/CheatSheet.svelte";
  import KeyHint from "../components/ui/KeyHint.svelte";
  import { keyHold } from "../lib/key-hold.svelte";
  import { numberHint } from "../lib/key-hold";
  import { Trail } from "../lib/trail";
  import { LAYOUT, dragged, panelWidth, sidebarWidth, storeWidth, storedWidth } from "../lib/panel-resize";
  import { SPLIT_CHOICES, TAB_MARKS, isSplitTab, splitLanding, splitSide, type SplitTab } from "../lib/panel-split";
  import { split } from "../lib/tab-windows.svelte";
  import SplitButton from "../components/shell/SplitButton.svelte";
  import BesideHost from "../components/shell/BesideHost.svelte";
  import CloneNotices from "../components/shell/CloneNotices.svelte";
  import StorageNotices from "../components/shell/StorageNotices.svelte";
  import NoticeBell from "../components/shell/NoticeBell.svelte";
  import { showChat } from "../lib/chat-arrived.svelte";
  import { tip } from "../components/ui/tip";
  import { keys as keyRules } from "../lib/keybindings.svelte";
  import { onCommands, runCommand } from "../lib/commands";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { connectorEvents } from "../lib/connectors";
  import { trayLive, type TrayEvent } from "../lib/tray-live";
  import { loadWeights } from "../lib/attention-rank";
  import { locale } from "../lib/i18n.svelte";
  import { QuitHold, quitInput, type QuitHint } from "../lib/quit-hold";
  import { companion } from "../lib/companion";
  import { companionHome, setLocal, shell } from "../lib/companion-shell.svelte";
  import Companion from "./companion/Companion.svelte";
  import { onBack, setupMobile } from "../lib/mobile";
  import { gamer } from "../lib/gamer.svelte";
  import { pullRequests } from "../lib/pulls.svelte";
  import { agents } from "../lib/agents.svelte";
  import { chatsShell } from "../lib/chats-shell.svelte";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import type { Target } from "../lib/inbox";
  import type { ChatTerminal } from "../lib/types";
  import { tr } from "../lib/i18n.svelte";
  import MicButton from "../components/MicButton.svelte";
  import WindowControls from "../components/WindowControls.svelte";
  import Menu, { type MenuItem } from "../components/ui/Menu.svelte";
  import { ask } from "../lib/confirm.svelte";
  import { recoverDeletedConversation } from "../lib/conversation-list";
  import Music from "./services/Music.svelte";
  import { footerState, startUpdates, updater, updates } from "../lib/updates.svelte";

  let route = $state<Route>(resumeRoute());
  // Settings takes the whole window, as the Mac's Settings window has the screen to itself: its Back returns here.
  let beforeSettings = $state<Route>("chat");
  $effect.pre(() => {
    if (route !== "settings") beforeSettings = route;
  });
  $effect(() => {
    const back = () => (route = beforeSettings);
    window.addEventListener(LEAVE_SETTINGS, back);
    return () => window.removeEventListener(LEAVE_SETTINGS, back);
  });
  let paletteOpen = $state(false);
  let chatTerminal = $state<ChatTerminal | null>(null);
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
  const settingsWhole = $derived(route === "settings" && !mobile);
  // The Agents tab can put its sidebar away (the Mac's `PanelSidebarToggle`); the toggle then floats in the same spot.
  const AGENTS_LIST_KEY = "agents.list.open";
  let agentsListOpen = $state((() => { try { return localStorage.getItem(AGENTS_LIST_KEY) !== "0"; } catch { return true; } })());
  const agentsListAway = $derived(route === "agents" && !agentsListOpen && !mobile);
  // With no chat app on yet, the Mac folds the sidebar to a rail of icons (search, then the tabs one under the other)
  // and puts the footer at the foot of the page instead (`PanelView.sidebarRail`, `ChatsTab.empty`).
  const railFolded = $derived(route === "chats" && chatsShell.folded && !mobile);
  function toggleAgentsList() {
    agentsListOpen = !agentsListOpen;
    try { localStorage.setItem(AGENTS_LIST_KEY, agentsListOpen ? "1" : "0"); } catch { /* remembering is a convenience */ }
  }
  // Windows: the window has no system title bar (`own_title_bar` in Rust); its buttons sit over the top right corner
  // and the headers in the top row move the window, as the Mac's title bar row does.
  const ownTitleBar = $derived(nook.info?.capabilities.os === "windows" && !mobile);

  // Hold Ctrl for a moment and the tabs show their Ctrl+number (the Mac's `CommandHoldMonitor`).
  $effect(() => keyHold.watch());
  const mac = typeof navigator !== "undefined" && /Mac/i.test(navigator.platform ?? "");

  // Hold Ctrl+Q to quit (the Mac's `QuitHoldMonitor`): a hint while you hold it, the quit when you let go after a second.
  // The quit goes through the tray's Quit, which asks first while sessions work.
  const quitHold = new QuitHold();
  let quitTimer: ReturnType<typeof setTimeout> | undefined;
  const quitTexts = () => ({
    hold: tr("Houd Ctrl+Q ingedrukt om Nook te stoppen", "Hold Ctrl+Q to quit Nook"),
    release: tr("Laat los om Nook te stoppen", "Release to quit Nook"),
  });
  function showQuitHint(hint: QuitHint) {
    const texts = quitTexts();
    for (const t of toast.shown) if (t.title === texts.hold || t.title === texts.release) toast.dismiss(t.id);
    if (hint !== "hidden") toast.info(texts[hint]);
  }
  function quitKey(e: KeyboardEvent) {
    if (android) return;
    const input = quitInput(e);
    if (!input || (input !== "pressed" && quitHold.idle)) return;
    // Ctrl+Q belongs to the shell inside a terminal.
    if (input === "pressed" && e.target instanceof Element && e.target.closest(".xterm")) return;
    if (input === "pressed") e.preventDefault();
    const out = quitHold.handle(input, performance.now());
    if (out.hint) showQuitHint(out.hint);
    clearTimeout(quitTimer);
    if (out.checkIn !== undefined) {
      const check = () => {
        const next = quitHold.handle("check", performance.now());
        if (next.hint) showQuitHint(next.hint);
        if (next.checkIn !== undefined) quitTimer = setTimeout(check, next.checkIn);
      };
      quitTimer = setTimeout(check, out.checkIn);
    }
    if (out.quit) invoke("quit_nook").catch(() => {});
  }
  $effect(() => {
    window.addEventListener("keydown", quitKey, true);
    window.addEventListener("keyup", quitKey, true);
    const blur = () => { if (!quitHold.idle) { quitHold.handle("otherKey", performance.now()); showQuitHint("hidden"); } };
    window.addEventListener("blur", blur);
    return () => {
      window.removeEventListener("keydown", quitKey, true);
      window.removeEventListener("keyup", quitKey, true);
      window.removeEventListener("blur", blur);
      clearTimeout(quitTimer);
    };
  });

  // The commands the shell offers itself (the rest belong to the views): the next or previous Nook or session in the
  // list (Ctrl+Shift+[ and ]), and on the Nook tab rename (F2) and pin (Ctrl+Shift+P) for the open conversation.
  $effect(() => keyRules.start());
  function step(delta: number) {
    if (route === "agents") {
      const ids = agents.sessions.map((s) => s.id);
      if (!ids.length) return false;
      const at = ids.indexOf(agents.selectedId ?? "");
      agents.select(ids[Math.min(ids.length - 1, Math.max(0, at < 0 ? 0 : at + delta))]);
      return true;
    }
    if (route !== "chat") return false;
    const ids = nook.nooks.filter((n) => !n.archived).map((n) => n.id);
    const at = ids.indexOf(nook.activeId ?? "");
    const next = ids[Math.min(ids.length - 1, Math.max(0, at < 0 ? 0 : at + delta))];
    if (next && next !== nook.activeId) nook.select(next).catch(() => {});
    return !!next;
  }
  $effect(() => onCommands({
    "session.previous": () => step(-1),
    "session.next": () => step(1),
    "session.rename": () => { if (route !== "chat" || !nook.active?.messages.length) return false; startRename(); },
    "session.pin": () => {
      const active = nook.active;
      if (route !== "chat" || !active) return false;
      api.setNookFlags(active.id, { pinned: !active.pinned }).then(() => nook.refreshList()).then(() => nook.load(active.id)).catch(() => {});
    },
  }));

  // The cheat sheet over the window (`?` or Ctrl+/, the Mac's `ShortcutCheatSheetView`).
  let cheatSheetOpen = $state(false);

  // Back and forward through the Nooks you opened (Ctrl+[ and Ctrl+], ⌘[ and ⌘] on the Mac); the Agents tab keeps
  // its own trail of sessions and pages (`agents.back()`).
  const nookTrail = new Trail<string>();
  let trailVersion = $state(0);
  let walking = false;
  $effect(() => {
    const id = nook.activeId;
    if (!id || walking) return;
    untrack(() => {
      nookTrail.visit(id);
      trailVersion += 1;
    });
  });
  async function walk(step: "back" | "forward") {
    if (route === "agents") return step === "back" ? agents.back() : agents.forward();
    if (route !== "chat") return;
    const id = step === "back" ? nookTrail.back() : nookTrail.forward();
    trailVersion += 1;
    if (!id) return;
    walking = true;
    try { await nook.select(id); }
    catch { nookTrail.drop(id); trailVersion += 1; }
    finally { walking = false; }
  }

  // The sidebar's width: drag its edge, double-click it to go back to 280 (the Mac's `resizablePanel`).
  const SIDEBAR_WIDTH_KEY = "nook.sidebar.width";
  let sidebarStored = $state(storedWidth(SIDEBAR_WIDTH_KEY, LAYOUT.sidebar));
  let sidebarLive = $state<number | null>(null);
  const sidebarShown = $derived(sidebarWidth(sidebarLive ?? sidebarStored, width));
  // The full layout: a sidebar beside the page (not the phone's tab bar, not the narrow window's icon rail).
  const fullLayout = $derived(!mobile && !narrow);

  // Split view: a second tab beside this one (`PanelSplitChoice`), and tabs torn off into a window of their own,
  // opened again after a restart.
  $effect(() => split.follow());
  let windowsReopened = false;
  $effect(() => {
    if (windowsReopened || !nook.info || android) return;
    windowsReopened = true;
    split.reopen();
  });
  const contentRoom = $derived(width - (settingsWhole || agentsListAway ? 0 : railFolded ? 88 : sidebarShown));
  const splitFits = $derived(contentRoom >= LAYOUT.minimumPanel + LAYOUT.minimumConversation + LAYOUT.handle);
  const splitTab = $derived<SplitTab | null>(fullLayout && !settingsWhole && splitFits ? splitSide(split.stored, route) : null);
  let splitLive = $state<number | null>(null);
  const splitShown = $derived(panelWidth(splitLive ?? split.width, LAYOUT.minimumPanel, contentRoom, LAYOUT.minimumConversation + LAYOUT.handle));
  const columns = $derived.by(() => {
    if (!fullLayout) return undefined;
    const rail = settingsWhole || agentsListAway ? null : railFolded ? "88px" : `${sidebarShown}px`;
    return [rail, "minmax(0, 1fr)", splitTab ? `${splitShown}px` : null].filter(Boolean).join(" ");
  });
  /// Where a request to open `next` lands: in the pane beside when that tab already shows there (`landing`).
  const land = (next: Route): Route => (splitTab ? splitLanding(next, route, split.stored) : next);
  /// Makes the tab beside the main one, and the main tab the one beside it.
  function swapSplit() {
    const side = splitTab;
    if (!side) return;
    split.choose(isSplitTab(route) ? route : null);
    navigate(side);
  }

  /// Drags a panel's edge: the panel follows the pointer once per frame, and its width is stored once, at the end.
  function dragLine(e: PointerEvent, start: number, leading: boolean, live: (width: number) => void, end: () => void) {
    if (e.button !== 0) return;
    e.preventDefault();
    const line = e.currentTarget as HTMLElement;
    line.setPointerCapture(e.pointerId);
    const from = e.clientX;
    let frame = 0;
    const move = (m: PointerEvent) => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => live(dragged(start, m.clientX - from, leading)));
    };
    const up = () => {
      cancelAnimationFrame(frame);
      line.removeEventListener("pointermove", move);
      line.removeEventListener("pointerup", up);
      line.removeEventListener("pointercancel", up);
      document.documentElement.classList.remove("resizing");
      end();
    };
    line.addEventListener("pointermove", move);
    line.addEventListener("pointerup", up);
    line.addEventListener("pointercancel", up);
    document.documentElement.classList.add("resizing");
  }
  function dragSidebar(e: PointerEvent) {
    dragLine(e, sidebarShown, false, (w) => (sidebarLive = sidebarWidth(w, width)), () => {
      if (sidebarLive !== null) { sidebarStored = sidebarLive; storeWidth(SIDEBAR_WIDTH_KEY, sidebarLive); }
      sidebarLive = null;
    });
  }
  function resetSidebar() {
    sidebarStored = LAYOUT.sidebar;
    storeWidth(SIDEBAR_WIDTH_KEY, LAYOUT.sidebar);
  }
  function dragSplit(e: PointerEvent) {
    dragLine(e, splitShown, true, (w) => (splitLive = panelWidth(w, LAYOUT.minimumPanel, contentRoom, LAYOUT.minimumConversation + LAYOUT.handle)), () => {
      if (splitLive !== null) split.setWidth(splitLive);
      splitLive = null;
    });
  }
  const resizeHelp = $derived(tr("Sleep om dit paneel breder of smaller te maken; dubbelklik om terug te zetten", "Drag to make this panel wider or narrower; double-click to reset"));

  /// F6 and Shift+F6: the next area of the window (sidebar, page, composer, the tab beside), as `focus.next`.
  function cycleFocus(backwards: boolean) {
    const areas = FOCUS_AREAS.map((sel) => document.querySelector<HTMLElement>(sel)).filter((el): el is HTMLElement => !!el && el.getClientRects().length > 0);
    const active = document.activeElement;
    // The innermost area holding the focus: the composer sits inside the page.
    let current = -1;
    areas.forEach((area, i) => { if (area.contains(active) && (current < 0 || areas[current].contains(area))) current = i; });
    const next = areas[nextArea(current, areas.length, backwards)];
    if (!next) return;
    const focusable = "button:not(:disabled), input, textarea, select, a[href], [tabindex='0'], [contenteditable='true']";
    const target = next.matches(focusable) ? next
      : next.querySelector<HTMLElement>("[aria-selected='true'], [aria-current='page']") ?? next.querySelector<HTMLElement>(focusable) ?? next;
    if (!target.matches(focusable) && !target.hasAttribute("tabindex")) target.tabIndex = -1;
    target.focus();
  }

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

  // A paired Android phone is the companion, laid out as the iPhone app (`companion-shell`).
  $effect(() => {
    if (!android) return;
    companion.client().then((v) => (shell.paired = v.phase === "connected" || v.phase === "offline")).catch(() => {});
  });
  const phoneShell = $derived(companionHome(android));

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
      // In the companion, shared text goes to the computer: a new session, a session or a question to Nook.
      if (companionHome(android)) return void (shell.shared = text);
      route = "chat";
      await nook.newNook();
      showList = false;
      await nook.ask(text);
    }, (url) => {
      // A pairing code or a prompt link: the companion handles both, also to pair while Nook on the phone is open.
      shell.link = url;
      if (/^nook:\/\/(pair|companion)/i.test(url)) { setLocal(false); route = "companion"; }
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
  /// Where a notice in the history leads (`notice_history`): a session, a chat by its inbox key, a Nook, or a page.
  function openNoticeRoute(r: string) {
    if (r.startsWith("agent:")) {
      agents.select(r.slice(6));
      return navigate(land("agents"));
    }
    if (r.startsWith("chat:")) {
      const key = r.slice(5);
      navigate(land("chats"));
      tick().then(() => window.dispatchEvent(new CustomEvent("nook-open-chat", { detail: key })));
      return;
    }
    applyRoute(r);
  }

  function applyRoute(r: string) {
    // "settings:<subject>": Settings at that subject (`open_settings` from the chat).
    if (r.startsWith("settings:")) {
      try { localStorage.setItem("settings.section", r.slice(9)); } catch { /* opens on the last page instead */ }
      route = "settings";
      return;
    }
    if (r.startsWith("nook:")) {
      route = "chat";
      if (mobile) showList = false;
      const target = r.slice(5);
      if (target !== nook.activeId || !nook.active) nook.select(target).catch(() => {});
    } else route = parseRoute(r);
  }

  $effect(() => {
    api.takeRoute().then((r) => r && applyRoute(r));
    api.takeChatTerminal().then((t) => {
      if (t) chatTerminal = t;
    });
    const unNav = events.onNavigate((r) => {
      applyRoute(r);
      api.takeRoute();
    });
    const unTerm = events.onChatTerminal((t) => {
      chatTerminal = t;
      api.takeChatTerminal();
    });
    // Quit from the tray while sessions work: Nook's own question with the "Don't ask again" box (`request_quit`).
    const unQuit = listen<number>("quit-ask", async (e) => {
      const n = e.payload;
      const yes = await ask({
        question: n === 1 ? tr("Er werkt nog een sessie", "A session is still working") : tr("Er werken nog {n} sessies", "{n} sessions are still working", { n }),
        detail: tr("Als je Nook stopt, stoppen zij ook. Je kunt ze voortzetten zodra je Nook weer opent.", "Quitting Nook stops them. You can continue them after you open Nook again."),
        confirmTitle: tr("Toch stoppen", "Quit Anyway"),
        destructive: false,
        dontAskAgain: tr("Niet meer vragen", "Don't ask again"),
        onRemember: () => { nook.saveSettings({ confirmQuit: false }).catch(() => {}); },
      });
      if (yes) invoke("quit_now").catch(() => {});
    });
    return () => {
      unNav.then((f) => f());
      unTerm.then((f) => f());
      unQuit.then((f) => f());
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
    ...(playing || route === "music" || split.stored === "music" ? [{ route: "music" as Route, icon: "voice" as const }] : []),
  ]);
  // Nook's own pages beyond the Mac's: Workspace, Gamer Mode and, on a paired PC, Companion. They open from search
  // (Ctrl+K), their Ctrl+number and, on the phone, the tab bar; the footer keeps the Mac's icons.
  const extras = $derived<{ route: Route; icon: TabIcon }[]>([
    ...(nook.info?.capabilities.terminals ? [{ route: "workspace" as Route, icon: "workspace" as const }] : []),
    { route: "games", icon: "gamepad" },
    ...(companionClient ? [{ route: "companion" as Route, icon: "phone" as const }] : []),
  ]);
  // The tabs' marks on the Mac (`PanelSplitChoice.symbol`): Nook's sparkles, a prompt for Agents, two bubbles for Chats.
  const tabMarks: Partial<Record<Route, string>> = { chat: "sparkles", agents: "terminal", chats: "messages-square", music: "audio-waveform" };
  // Ctrl+1 … Ctrl+9 in the order they show: the tabs, then the footer's pages.
  const pages = $derived([...tabs, ...extras]);
  // Which footer page the Agents tab shows (pull requests, Actions or usage), to light its button.
  const agentsPage = $derived(route === "agents" ? agents.selectedId : null);
  // Amber count on the Agents tab while sessions wait for your reply or approval (`PanelView.tabItems`).
  const agentsWaiting = $derived(agents.sessions.filter((s) => s.status === "waiting" || !!s.approvalId).length);

  function keys(e: KeyboardEvent) {
    const target = e.target instanceof Element ? e.target : null;
    // One Escape order, innermost first: a menu, dropdown or dialog (each closes itself in the capture phase), the cheat
    // sheet, the palette, the floating list, then Settings; only after that does the page's own Escape run (stop an
    // answer, close an open chat).
    if (e.key === "Escape" && overlay && !paletteOpen) { showList = false; return; }
    // Escape leaves Settings, as closing the Mac's Settings window does, unless a field or a dialog has it.
    if (e.key === "Escape" && settingsWhole && !paletteOpen && !e.defaultPrevented
      && !target?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')
      && !document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]')) { route = beforeSettings; return; }
    // Alt+Left and Alt+Right walk back and forward through the sessions you opened (⌘[ and ⌘] on the Mac).
    if (route === "agents" && e.altKey && !e.ctrlKey && !e.metaKey && (e.key === "ArrowLeft" || e.key === "ArrowRight")
      && !target?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), .xterm')) {
      e.preventDefault();
      if (e.key === "ArrowLeft") agents.back(); else agents.forward();
      return;
    }
    const terminal = !!target?.closest(".xterm");
    const shortcut = shellShortcut(e, {
      paletteOpen, chat: route === "chat",
      modalOpen: !!document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]'),
      editing: !!target?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], .xterm'),
      terminal,
      composer: !!target?.closest("textarea, [contenteditable='true']") && !!target?.closest(".composer, .run-composer, form"),
      panel: !!target?.closest(".beside, .terminal-pane, aside"),
    }, keyRules.rules);
    if (!shortcut) return;
    // A command for the view on screen (`onCommand`): the key is taken only when something handled it.
    if (shortcut.startsWith("cmd:")) {
      if (runCommand(shortcut.slice(4))) e.preventDefault();
      return;
    }
    // Ctrl+F belongs to the shell inside a terminal, and Ctrl+[ is Escape there.
    if ((shortcut === "search" || shortcut === "back" || shortcut === "forward") && terminal) return;
    // A view that offers its own new, find or stop (a new agent session, find in a session) goes first.
    const own = ({ new: "session.new", search: "chat.find", stop: "session.interrupt" } as Record<string, string>)[shortcut];
    if (own && route !== "chat" && runCommand(own)) { e.preventDefault(); return; }
    const page = shortcut.startsWith("go-") ? pages[Number(shortcut.slice(3)) - 1] : undefined;
    if (shortcut.startsWith("go-") && !page) return;
    e.preventDefault();
    switch (shortcut) {
      case "palette": paletteOpen = !paletteOpen; break;
      case "sidebar": if (route === "agents" && !mobile) toggleAgentsList(); else showList = !showList; break;
      case "new":
        route = "chat";
        showList = !mobile;
        nook.newNook();
        break;
      case "settings": route = "settings"; break;
      case "stop": nook.stop(); break;
      case "back": case "forward": walk(shortcut); break;
      case "cheatsheet": cheatSheetOpen = !cheatSheetOpen; break;
      case "focus-next": case "focus-previous": cycleFocus(shortcut === "focus-previous"); break;
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
    // Back from Nook on the phone to the paired computer.
    if (next === "companion" && android && shell.paired) return setLocal(false);
    route = next;
    if (next === "chat" && mobile) showList = false;
  }

  // The footer's update button (`UpdateFooterButton` on the Mac): only when there is something to say.
  startUpdates();
  const updateState = $derived(footerState(updater.status));
  const updateLabel = $derived(({
    available: tr("Update naar {version}", "Update to {version}", { version: updater.status?.candidate?.version ?? "" }),
    installing: tr("Bijwerken…", "Updating…"),
    ready: tr("Herstarten", "Restart"),
    failed: tr("Update mislukt", "Update failed"),
    updated: tr("Bijgewerkt naar {version}", "Updated to {version}", { version: updater.status?.receipt?.to ?? "" }),
  } as const)[updateState ?? "available"]);
  // The tray menu's status lines and the taskbar badge (the Mac's menu bar menu and Dock badge): the next meeting, the
  // agents, what needs you, the music and an update, sent to Rust a moment after they change.
  let trayEvents = $state<TrayEvent[] | null>(null);
  $effect(() => {
    if (!nook.info?.capabilities.tray) return;
    agents.start();
    const load = () => invoke<TrayEvent[]>("agenda_upcoming", { hours: 12 }).then((e) => (trayEvents = e)).catch(() => (trayEvents = null));
    load();
    const timer = setInterval(load, 5 * 60_000);
    const un = connectorEvents.onChanged(load);
    return () => { clearInterval(timer); un.then((f) => f()); };
  });
  let trayTick = $state(Date.now());
  $effect(() => {
    const timer = setInterval(() => (trayTick = Date.now()), 60_000);
    return () => clearInterval(timer);
  });
  // How welcome each agent is from what you did with its notices, for the tray's "Needs you" (the shared ranking).
  let trayWeights = $state(new Map<string, number>());
  $effect(() => {
    if (!nook.info?.capabilities.tray) return;
    const items = agents.sessions.map((s) => ({ source: "agents", id: s.id, app: s.name, subject: s.id, needsYou: "question" as const }));
    void trayTick;
    loadWeights(items).then((w) => (trayWeights = w));
  });
  const trayInfo = $derived(nook.info?.capabilities.tray ? trayLive({
    now: trayTick, locale: locale(), events: trayEvents, sessions: agents.sessions, nooks: nook.nooks, playing,
    update: updateState, updateVersion: updater.status?.candidate?.version ?? null, weights: trayWeights,
  }) : null);
  const trayKey = $derived(trayInfo ? JSON.stringify(trayInfo) : "");
  $effect(() => {
    if (!trayKey) return;
    const timer = setTimeout(() => invoke("tray_live", { live: JSON.parse(trayKey) }).catch(() => {}), 400);
    return () => clearTimeout(timer);
  });

  function openUpdates() {
    openTarget({ kind: "settings", section: "maintenance" });
  }

  /// The footer's refresh (as on the Mac): reads the session lists again and checks for an update. The arrows turn
  /// while it runs; a check you asked for says so when Nook is up to date.
  let refreshing = $state(false);
  async function refresh() {
    refreshing = true;
    try {
      const [, status] = await Promise.all([agents.refresh(), updates.check()]);
      if (status?.phase === "upToDate") toast.success(tr("Nook is up-to-date", "Nook is up to date"));
    } catch (e) {
      toast.error(tr("Vernieuwen mislukt", "Refresh failed"), e);
    } finally {
      refreshing = false;
    }
  }

  /// Opens a page of the Agents tab: pull requests, Actions or usage (the footer's buttons, as on the Mac).
  // Where you were before a footer page (pull requests, Actions): its "Back" returns there (`PanelFooter.onBack`).
  let beforeFooterPage = $state<{ route: Route; selected: string | null } | null>(null);
  function openAgentsPage(page: "pulls" | "actions" | "usage") {
    const onPage = route === "agents" && (agents.selectedId === "pulls" || agents.selectedId === "actions");
    if (page !== "usage" && !onPage) beforeFooterPage = { route, selected: agents.selectedId };
    agents.select(page);
    navigate("agents");
  }
  function leaveFooterPage() {
    const back = beforeFooterPage;
    beforeFooterPage = null;
    if (back && back.route !== "agents") {
      navigate(back.route);
      return;
    }
    agents.select(back?.selected === "pulls" || back?.selected === "actions" ? null : (back?.selected ?? null));
  }
  const onFooterPage = $derived(route === "agents" && (agents.selectedId === "pulls" || agents.selectedId === "actions"));

  /// Opens what the empty chat's rows and cards point at.
  async function openTarget(target: Target) {
    try {
      switch (target.kind) {
        case "route": return navigate(land(target.route));
        case "settings":
          try { localStorage.setItem("settings.section", target.section); } catch { /* opens on the last page instead */ }
          return navigate("settings");
        case "workspace":
          if (target.page === "usage" || !nook.info?.capabilities.terminals) return openAgentsPage(target.page === "usage" ? "usage" : "pulls");
          try { localStorage.setItem("ws.page", target.page); } catch { /* opens on the last page instead */ }
          return navigate("workspace");
        case "agents":
          agents.select(target.select);
          return navigate(land("agents"));
        case "nook":
          navigate(land("chat"));
          return await nook.select(target.id);
        case "chat":
          navigate(land("chats"));
          await tick();
          return showChat(target.key);
        case "newNook":
          navigate(land("chat"));
          await nook.newNook();
          if (target.ask) await nook.ask(target.ask);
          return;
      }
    } catch (e) {
      nook.error = String(e);
    }
  }

  // The header's "…" menu, as the Mac's `conversationMenu`.
  let moreAnchor = $state<DOMRect | null>(null);
  function startRename() {
    titleDraft = nook.active?.title ?? "";
    renaming = true;
  }
  const moreSections = $derived.by((): MenuItem[][] => {
    const active = nook.active;
    if (!active) return [];
    const id = active.id;
    const flags = async (f: { pinned?: boolean; archived?: boolean }) => {
      try { await api.setNookFlags(id, f); await nook.refreshList(); await nook.load(id); }
      catch (e) { toast.error(tr("Kon het gesprek niet aanpassen", "Could not change conversation"), e); }
    };
    return [
      [
        { label: tr("Hernoem", "Rename"), icon: "pencil", onselect: startRename },
        { label: active.pinned ? tr("Maak los", "Unpin") : tr("Zet vast", "Pin"), icon: active.pinned ? "pin-off" : "pin", onselect: () => flags({ pinned: !active.pinned }) },
        { label: tr("Kopieer gesprek als Markdown", "Copy conversation as Markdown"), icon: "copy", onselect: copyConversation },
      ],
      [
        { label: tr("Archiveer", "Archive"), icon: "archive", disabled: nook.busy, onselect: () => flags({ archived: true }) },
        { label: tr("Verwijder", "Delete"), icon: "trash-2", destructive: true, disabled: nook.busy, onselect: async () => {
          const yes = await ask({ question: tr("“{title}” verwijderen?", "Delete “{title}”?", { title: active.title }), detail: tr("Het gesprek is daarna weg.", "The conversation will be gone."), confirmTitle: tr("Verwijder", "Delete") });
          if (!yes) return;
          try { await api.deleteNook(id); await recoverDeletedConversation(nook, id); }
          catch (e) { toast.error(tr("Kon het gesprek niet verwijderen", "Could not delete conversation"), e); }
        } },
      ],
    ];
  });

  async function copyConversation() {
    if (!nook.active?.messages.length) return;
    try {
      await navigator.clipboard.writeText(conversationMarkdown(nook.active, nook.streaming));
      toast.success(tr("Gesprek gekopieerd", "Conversation copied"), tr("Tekst gekopieerd als Markdown.", "Text copied as Markdown."));
    } catch (e) { toast.error(tr("Kon het gesprek niet kopiëren", "Could not copy conversation"), e); }
  }
</script>

<svelte:window onkeydown={keys} bind:innerWidth={width} />

{#if phoneShell}
<div class="phone-shell"><Companion standalone /></div>
{:else}
<div class="main" class:mobile class:overlay class:own-title-bar={ownTitleBar} class:settings-whole={settingsWhole} class:list-away={agentsListAway} class:rail-folded={railFolded} class:has-split={!!splitTab} style:grid-template-columns={columns}>
  {#if ownTitleBar}<WindowControls />{/if}
  {#if agentsListAway}
    <button class="ghost icon-button float-toggle" onclick={toggleAgentsList} use:tip={tr("Sessielijst tonen (Ctrl+B)", "Show session list (Ctrl+B)")} aria-label={tr("Sessielijst tonen", "Show session list")} aria-expanded="false"><Ico name="panel-left" size={16} /></button>
  {/if}
  <nav class="rail" aria-label={tr("Hoofdnavigatie", "Main navigation")}>
    <div class="head" data-tauri-drag-region>
      <!-- The Mac's title bar row (`PanelSidebarTop`): on Agents the list toggle and back and forward through the
           sessions you opened (`SessionHistoryButtons`), then search everything and talk. -->
      {#if route === "agents" && !mobile}
        <button class="ghost icon-button on" onclick={toggleAgentsList} use:tip={tr("Sessielijst verbergen (Ctrl+B)", "Hide session list (Ctrl+B)")} aria-label={tr("Sessielijst verbergen", "Hide session list")} aria-expanded="true"><Ico name="panel-left" size={16} /></button>
        <button class="ghost icon-button" disabled={!agents.canBack} onclick={() => agents.back()} use:tip={tr("Terug (Ctrl+[)", "Back (Ctrl+[)")} aria-label={tr("Terug", "Back")}><Ico name="arrow-left" size={15} /></button>
        <button class="ghost icon-button" disabled={!agents.canForward} onclick={() => agents.forward()} use:tip={tr("Vooruit (Ctrl+])", "Forward (Ctrl+])")} aria-label={tr("Vooruit", "Forward")}><Ico name="arrow-right" size={15} /></button>
      {/if}
      <span class="spacer" data-tauri-drag-region></span>
      <button class="ghost icon-button" onclick={() => (paletteOpen = true)} use:tip={tr("Zoek overal (Ctrl+K)", "Search everything (Ctrl+K)")} aria-label={tr("Zoek overal", "Search everything")}><Icon name="search" size={15} /></button>
      <span class="talk"><MicButton size={15} /></span>
      {#if fullLayout}<NoticeBell onopen={openNoticeRoute} /><SplitButton current={route} {titleOf} />{/if}
      <!-- A narrow window floats the conversation list over the page: its toggle sits here (Ctrl+B everywhere). -->
      {#if route === "chat" && narrow}<button class="ghost icon-button" onclick={() => (showList = !showList)} use:tip={showList ? tr("Verberg gesprekken", "Hide conversations") : tr("Toon gesprekken", "Show conversations")} aria-label={tr("Gesprekken tonen of verbergen", "Toggle conversations")} aria-expanded={showList}><Icon name="sidebar" size={16} /></button>{/if}
    </div>
    {#if railFolded}<button class="rail-search" onclick={() => (paletteOpen = true)} use:tip={tr("Zoek overal (Ctrl+K)", "Search everything (Ctrl+K)")} aria-label={tr("Zoek overal", "Search everything")}><Ico name="search" size={13} /></button>{/if}
    <div class="tabbar" role="tablist">
      {#each tabs as tab, i (tab.route)}
        {@const beside = splitTab === tab.route}
        <button role="tab" class="tab" class:on={route === tab.route} class:beside aria-selected={route === tab.route} aria-current={route === tab.route ? "page" : undefined} aria-label={beside ? `${titleOf(tab.route)}, ${tr("Ernaast geopend", "Open beside")}` : titleOf(tab.route)}
          onclick={() => { if (tab.route === "chat" && mobile && route === "chat") showList = !showList; if (beside) swapSplit(); else navigate(tab.route); }}
          use:tip={route === tab.route || mobile ? null : i < 9 ? `${titleOf(tab.route)} (Ctrl+${i + 1})` : titleOf(tab.route)}>
          {#if tabMarks[tab.route]}<Ico name={tabMarks[tab.route]!} size={15} stroke={1.8} />{:else}<Icon name={tab.icon} size={16} />{/if}<span>{titleOf(tab.route)}</span>
          {#if tab.route === "agents" && agentsWaiting > 0}<b class="tab-badge" aria-label={tr("{n} wachten op je", "{n} need you", { n: agentsWaiting })}>{agentsWaiting}</b>{/if}
          {#if keyHold.held && !mobile && numberHint(i, mac)}<span class="tab-hint"><KeyHint text={numberHint(i, mac)!} /></span>{/if}
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
        {#if route === "chat" && showList}<NookList onopen={openTarget} />{/if}
      </div>
      <!-- The Mac's footer (`PanelFooter`): Settings, pull requests, Actions and usage as quiet icons, and one refresh at the
           far end that the update button replaces while there is one. -->
      <div class="footer">
        {#if onFooterPage}
          <!-- On a footer page the icons make way for one way back, as the Mac's footer does. -->
          <button class="ghost foot back" onclick={leaveFooterPage}><Ico name="chevron-left" size={15} /><span>{tr("Terug", "Back")}</span></button>
        {:else}
        <button class="ghost foot" class:on={route === "settings"} aria-current={route === "settings" ? "page" : undefined} onclick={() => navigate("settings")} use:tip={tr("Instellingen (Ctrl+,)", "Settings (Ctrl+,)")} aria-label={tr("Instellingen", "Settings")}><Icon name="settings" size={17} /></button>
        <button class="ghost foot" class:on={agentsPage === "pulls"} onclick={() => openAgentsPage("pulls")} use:tip={"Pull requests"} aria-label="Pull requests"><PullGlyph size={16} /></button>
        <button class="ghost foot" class:on={agentsPage === "actions"} onclick={() => openAgentsPage("actions")} use:tip={`Actions · ${tr("Workflow-runs van een repository: CI, promotes, releases", "Workflow runs of a repository: CI, promotes, releases")}`} aria-label="Actions"><Ico name="circle-play" size={17} /></button>
        <button class="ghost foot" class:on={agentsPage === "usage"} onclick={() => openAgentsPage("usage")} use:tip={tr("Gebruik", "Usage")} aria-label={tr("Gebruik", "Usage")}><Icon name="chart" size={17} /></button>
        {/if}
        <span class="spacer"></span>
        {#if updateState}
          <button class="ghost update" class:available={updateState === "available" || updateState === "ready"} class:failed={updateState === "failed"} onclick={openUpdates} use:tip={updateState === "available" ? updateLabel : null} aria-label={updateLabel}>
            <Icon name={updateState === "installing" ? "loader" : updateState === "failed" ? "alert" : updateState === "updated" ? "circle-check" : "arrow"} size={14} />
            <span>{updateState === "available" ? tr("Update", "Update") : updateLabel}</span>
          </button>
        {:else if !onFooterPage}
          {@const refreshLabel = tr("Vernieuwen en op updates controleren", "Refresh and check for updates")}
          <button class="ghost foot" onclick={refresh} disabled={refreshing} use:tip={refreshLabel} aria-label={refreshLabel}><span class="turn" class:spin={refreshing}><Ico name="refresh-cw" size={16} /></span></button>
        {/if}
      </div>
    {/if}
    {#if fullLayout && !railFolded && !settingsWhole && !agentsListAway}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="resize-line rail-line" role="separator" aria-orientation="vertical" aria-label={resizeHelp} title={resizeHelp}
        onpointerdown={dragSidebar} ondblclick={resetSidebar}></div>
    {/if}
  </nav>
  <section class="content" aria-label={routeTitle}>
    {#if route === "chat"}
      {@const terminalBeside = !!(chatTerminal && !mobile && nook.info?.capabilities.terminals)}
      <div class="chatlayout" class:nolist={!mobile || !showList} class:has-terminal={terminalBeside}>
        {#if mobile && showList}
          <div class="listwrap" role="presentation" onclick={(e) => {
            const t = e.target as HTMLElement;
            if (t.closest(".item") && !t.closest(".menu") && !t.closest(".menu-trigger")) showList = false;
          }}>
            <NookList onopen={openTarget} />
          </div>
        {/if}
        <div class="chatpane">
          {#if mobile}
          <header class="title" data-tauri-drag-region>
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
              <span class="spacer" data-tauri-drag-region></span>
              <button class="ghost icon-button" disabled={!nook.active?.messages.length} onclick={copyConversation} title={tr("Kopieer gesprek als Markdown", "Copy conversation as Markdown")} aria-label={tr("Kopieer gesprek als Markdown", "Copy conversation as Markdown")}><Icon name="copy" size={16} /></button>
              <button class="ghost icon-button" onclick={() => { nook.newNook(); if (mobile) showList = false; }} title={tr("Nieuwe Nook (Ctrl+N)", "New Nook (Ctrl+N)")} aria-label={tr("Nieuwe Nook", "New Nook")}><Icon name="plus" size={16} /></button>
          </header>
          {:else}
            <!-- The Mac's conversation header (`NookTab.header`): the title and a "…" menu, nothing on an empty Nook; a new
                 Nook starts from the list's head. The row still moves the window. -->
            <header class="title" class:bare={!nook.active?.messages.length} data-tauri-drag-region>
              {#if nook.active?.messages.length}
                {#if renaming}
                  <!-- svelte-ignore a11y_autofocus -->
                  <input class="rename" aria-label={tr("Titel van het gesprek", "Conversation title")} autofocus bind:value={titleDraft} onblur={commitRename}
                    onkeydown={(e) => { if (e.key === "Enter") commitRename(); else if (e.key === "Escape") { e.stopPropagation(); renaming = false; } }} />
                {:else}
                  <span class="name" use:tip={{ text: nook.active.title, whenCut: true }} ondblclick={startRename} role="heading" aria-level="1">{nook.active.title}</span>
                {/if}
                {#if nook.active.pinned}<span class="pinned" aria-label={tr("Vastgezet", "Pinned")}><Ico name="pin" size={10} /></span>{/if}
                <span class="spacer" data-tauri-drag-region></span>
                <!-- `NookTab.header`: the status while it works or waits for your yes, beside the menu. -->
                {@const headStatus = nook.nooks.find((n) => n.id === nook.active?.id)?.status}
                {#if headStatus === "working" || headStatus === "waiting"}<StatusPill attention={headStatus === "working" ? "working" : "approval"} />{/if}
                <button class="ghost icon-button more" onclick={(e) => (moreAnchor = (e.currentTarget as HTMLElement).getBoundingClientRect())} use:tip={tr("Meer acties", "More actions")} aria-label={tr("Meer acties", "More actions")} aria-haspopup="menu"><Ico name="ellipsis" size={15} /></button>
              {/if}
            </header>
          {/if}
          <Chat onopen={openTarget} />
        </div>
        {#if terminalBeside && chatTerminal}
          <aside class="terminal-pane" aria-label={tr("Terminals", "Terminals")}>
            <ChatTerminalPanel folder={chatTerminal.folder} focusId={chatTerminal.id} onclose={() => (chatTerminal = null)} />
          </aside>
        {/if}
      </div>
    {:else if route === "chats"}
      <!-- No page title: the Chats list's own head ("All chats") is the title, as on the Mac. -->
      <div class="route-body"><Chats onnook={(id) => { nook.select(id); route = "chat"; }} /></div>
    {:else if route === "music"}
      <header class="title page-title" data-tauri-drag-region><span class="name" data-tauri-drag-region>{routeTitle}</span></header>
      <div class="route-body music-body">
        {#if playing}<Music info={playing} since={playingSince} />{:else}<p class="faint quiet">{tr("Er speelt nu niets.", "Nothing is playing right now.")}</p>{/if}
      </div>
    {:else}
      {#if route !== "agents" && route !== "settings"}<header class="title page-title" data-tauri-drag-region><span class="name" data-tauri-drag-region>{routeTitle}</span></header>{/if}
      <div class="route-body">
        {#key route}<LazyView load={routeViews[route]!} label={routeTitle} onretry={() => reloadRoute(route)} />{/key}
      </div>
    {/if}
  </section>
  {#if splitTab}
    <!-- The second tab of split view (`PanelSplitPane`): its name, swap with the main tab, a window of its own, close. -->
    <aside class="beside" aria-label={titleOf(splitTab)}>
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div class="resize-line split-line" role="separator" aria-orientation="vertical" aria-label={resizeHelp} title={resizeHelp}
        onpointerdown={dragSplit} ondblclick={() => split.setWidth(LAYOUT.split)}></div>
      <header class="beside-head" data-tauri-drag-region>
        <span class="beside-mark"><Ico name={TAB_MARKS[splitTab]} size={14} /></span>
        <span class="beside-title" data-tauri-drag-region>{titleOf(splitTab)}</span>
        <span class="spacer" data-tauri-drag-region></span>
        <button class="ghost icon-button" onclick={swapSplit} use:tip={tr("Omwisselen met de hoofdtab", "Swap with the main tab")} aria-label={tr("Omwisselen met de hoofdtab", "Swap with the main tab")}><Ico name="arrow-left-right" size={14} /></button>
        <button class="ghost icon-button" onclick={() => splitTab && split.openWindow(splitTab).catch((e) => toast.error(tr("Kon het venster niet openen", "Could not open the window"), e))} use:tip={tr("In een eigen venster openen", "Open in its own window")} aria-label={tr("In een eigen venster openen", "Open in its own window")}><Ico name="app-window-mac" size={14} /></button>
        <button class="ghost icon-button" onclick={() => split.choose(null)} use:tip={tr("Gesplitst scherm sluiten", "Close split view")} aria-label={tr("Gesplitst scherm sluiten", "Close split view")}><Ico name="x" size={14} /></button>
      </header>
      <div class="beside-body">
        {#key splitTab}<BesideHost>{@render besidePage(splitTab)}</BesideHost>{/key}
      </div>
    </aside>
  {/if}
</div>
{/if}

{#snippet besidePage(tab: SplitTab)}
  {#if tab === "chat"}
    <div class="beside-chat"><Chat onopen={openTarget} /></div>
  {:else if tab === "chats"}
    <Chats onnook={(id) => { nook.select(id); navigate(land("chat")); }} />
  {:else if tab === "music"}
    {#if playing}<Music info={playing} since={playingSince} />{:else}<p class="faint quiet">{tr("Er speelt nu niets.", "Nothing is playing right now.")}</p>{/if}
  {:else}
    <LazyView load={routeViews.agents!} label={titleOf("agents")} props={{ compact: true }} />
  {/if}
{/snippet}

{#if moreAnchor}<Menu sections={moreSections} anchor={moreAnchor} onclose={() => (moreAnchor = null)} />{/if}
{#if !phoneShell}<CloneNotices /><StorageNotices />{/if}
{#if cheatSheetOpen}<CheatSheet onclose={() => (cheatSheetOpen = false)} onsettings={() => { cheatSheetOpen = false; openTarget({ kind: "settings", section: "shortcuts" }); }} />{/if}
{#if paletteOpen}<CommandPalette onclose={() => (paletteOpen = false)} onnavigate={navigate} companionEnabled={companionClient} />{/if}

<style>
  /* The main window as on the Mac: one sidebar (search, tab bar, the tab's list, footer) beside the content. */
  .main { display: grid; grid-template-columns: 280px minmax(0, 1fr); height: 100dvh; overflow: hidden; background: var(--canvas); }
  .rail { position: relative; background: var(--sidebar); border-right: 1px solid var(--border); display: flex; flex-direction: column; min-height: 0; padding: 0 var(--space-8) var(--space-16); }
  .head { display: flex; align-items: center; gap: 2px; height: 52px; padding: 0 4px; flex: none; }
  .talk { display: contents; }
  .talk :global(.mic) { width: 28px; height: 28px; border-radius: var(--radius-control); color: var(--text2); }
  .talk :global(.mic svg) { width: 16px; height: 16px; }
  .tabbar { display: flex; gap: 2px; padding: 2px; min-height: 34px; background: var(--surface); border-radius: var(--radius-card); flex: none; }
  .tab { display: flex; align-items: center; justify-content: center; gap: 6px; flex: 0 0 auto; min-width: 28px; height: 30px; padding: 0; background: transparent; border: 0; border-radius: var(--radius-control); color: var(--text3); font: var(--text-control); }
  .tab:not(.on) { flex: 1 1 0; }
  .tab span { display: none; }
  .tab.on { padding: 0 var(--space-8); gap: var(--space-6); background: var(--row-selected); color: var(--paper); }
  .tab.on span { display: inline; }
  .tab { position: relative; }
  /* The tab beside the main one (split view) is outlined; a click swaps the two. */
  .tab.beside { outline: 1px dashed var(--border); outline-offset: -1px; }
  .tab .tab-badge { display: inline-grid; place-items: center; min-width: 16px; height: 16px; padding: 0 var(--space-4); border-radius: var(--radius-pill); background: color-mix(in srgb, var(--amber) 22%, transparent); color: var(--amber); font: var(--text-badge); font-variant-numeric: tabular-nums; }
  .tab .tab-hint { position: absolute; top: -4px; right: -2px; display: inline-flex; }
  .tab .tab-hint :global(.key-hint) { display: inline-flex; }
  /* A panel's drag line (`EmbeddedSplitHandle`): invisible until the pointer is on it. */
  .resize-line { position: absolute; top: 0; bottom: 0; width: 8px; z-index: 6; cursor: col-resize; touch-action: none; }
  .resize-line::after { content: ""; position: absolute; top: 0; bottom: 0; left: 3px; width: 2px; background: transparent; transition: background var(--motion-hover, 120ms); }
  .resize-line:hover::after, :global(html.resizing) .resize-line::after { background: var(--line2); }
  .rail-line { right: -4px; }
  .split-line { left: -4px; }
  :global(html.resizing), :global(html.resizing *) { cursor: col-resize !important; user-select: none; }
  /* The tab beside the main one: its own header row, then the tab with its own list. */
  .beside { position: relative; min-width: 0; min-height: 0; height: 100%; display: flex; flex-direction: column; border-left: 1px solid var(--border); background: var(--canvas); }
  .beside-head { display: flex; align-items: center; gap: var(--space-4); min-height: 52px; padding: 0 var(--space-8) 0 var(--space-16); flex: none; }
  .main.own-title-bar .beside-head { padding-right: calc(var(--space-8) + var(--caption-room)); }
  .beside-mark { display: inline-flex; color: var(--text2); }
  .beside-title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .beside-body { flex: 1; min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
  .beside-body > :global(*) { flex: 1; min-height: 0; }
  .beside-chat { display: flex; flex-direction: column; min-height: 0; }
  .beside-chat :global(.chat) { flex: 1; min-height: 0; }
  .tab:hover:not(.on) { color: var(--text2); background: var(--row-hover); }
  .rule { height: 1px; background: var(--hairline); margin: var(--space-8) 0 var(--space-4); flex: none; }
  .side-list { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .side-list :global(.list) { flex: 1; background: transparent; border-right: 0; }
  .footer { display: flex; align-items: center; gap: var(--space-4); padding: var(--space-6) var(--space-4) 0; flex: none; margin-top: var(--space-4); }
  .foot.back { width: auto; flex: none; display: inline-flex; gap: var(--space-4); padding: 0 var(--space-8) 0 var(--space-4); font: var(--text-control); }
  .update { display: inline-flex; align-items: center; gap: var(--space-4); height: 26px; padding: 0 var(--space-8); border-radius: var(--radius-pill); font: var(--text-control); color: var(--text2); max-width: 160px; }
  .update span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .update.available { color: var(--mint); background: color-mix(in srgb, var(--mint) 14%, transparent); }
  .update.failed { color: var(--coral); }
  .spacer { flex: 1; }
  /* A footer icon as the Mac's `FooterIcon`: quiet until hovered or open. */
  .foot { display: grid; place-items: center; width: 32px; height: 30px; padding: 0; flex: 0 1 32px; min-width: 24px; border: 0; border-radius: var(--radius-control); color: var(--text3); }
  .foot:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
  .foot.on { background: var(--row-selected); color: var(--paper); }
  .turn { display: inline-flex; }
  .turn.spin { animation: turn 0.9s linear infinite; }
  @keyframes turn { to { transform: rotate(360deg); } }
  .icon-button { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; flex-shrink: 0; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .icon-button:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
  .icon-button.on { background: var(--smoke); color: var(--paper); }
  .icon-button:disabled { color: var(--text3); opacity: 0.5; }
  .music-body { overflow-y: auto; }
  .quiet { padding: 24px; text-align: center; }
  .content { min-width: 0; min-height: 0; height: 100%; overflow: hidden; display: flex; flex-direction: column; background: var(--canvas); }
  .chatlayout { display: grid; grid-template-columns: minmax(0, 1fr); height: 100%; min-height: 0; }
  .chatlayout.has-terminal { grid-template-columns: minmax(280px, 1fr) minmax(280px, 44%); }
  .terminal-pane { min-width: 0; min-height: 0; border-left: 1px solid var(--border); background: var(--canvas); display: flex; flex-direction: column; }
  .chatpane { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .listwrap :global(.list) { flex: 1; }
  .main.settings-whole { grid-template-columns: minmax(0, 1fr); }
  .main.settings-whole .rail { display: none; }
  .main.list-away { grid-template-columns: minmax(0, 1fr); }
  /* The folded rail: 88 px, a boxed search on top, the tabs as marks one under the other, a line under them. */
  .main.rail-folded { grid-template-columns: 88px minmax(0, 1fr); }
  .main.rail-folded .rail { padding: 0 var(--space-6) var(--space-16); align-items: center; }
  .main.rail-folded .head > :not(.spacer) { display: none; }
  .rail-search { display: grid; place-items: center; width: 38px; height: 32px; margin: 0 0 var(--space-12); padding: 0; flex: none; border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--surface); color: var(--text2); }
  .rail-search:hover { color: var(--paper); }
  .main.rail-folded .tabbar { flex-direction: column; align-items: center; gap: var(--space-4); padding: 0; background: transparent; min-height: 0; }
  .main.rail-folded .tab, .main.rail-folded .tab.on { flex: none; width: 38px; height: 32px; padding: 0; }
  .main.rail-folded .tab.on span { display: none; }
  .main.rail-folded .rule { align-self: stretch; margin: var(--space-8) calc(-1 * var(--space-6)) 0; }
  .main.rail-folded .side-list { display: none; }
  .main.rail-folded .footer { position: fixed; left: calc(88px + var(--space-12)); bottom: var(--space-16); width: 300px; margin: 0; padding: 0; z-index: 5; }
  .main.list-away .rail { display: none; }
  .float-toggle { position: fixed; top: var(--space-12); left: var(--space-8); z-index: 25; }
  /* Room for the window's buttons on Windows (`WindowControls`), at the right end of the top row. */
  .main.own-title-bar { --caption-room: calc(var(--caption-button) * 3); }
  .main.own-title-bar:not(.has-split) .chatlayout:not(.has-terminal) .title, .main.own-title-bar:not(.has-split) .page-title { padding-right: calc(var(--space-16) + var(--caption-room)); }
  .title { min-height: 52px; padding: 0 16px; display: flex; align-items: center; gap: 8px; min-width: 0; flex-shrink: 0; }
  .title .name.editable { background: transparent; border: 0; padding: 4px 8px; margin-left: -8px; border-radius: var(--radius-control); color: var(--paper); text-align: left; min-width: 0; }
  .title .name.editable:hover { background: var(--row-hover); }
  .rename { min-width: 0; flex: 0 1 360px; font: var(--text-title); padding: 4px 8px; margin-left: -8px; }
  /* An empty Nook has no header: Home starts at the top, as on the Mac; the row still moves the window. */
  .chatpane { position: relative; }
  .title.bare { position: absolute; inset: 0 0 auto 0; z-index: 1; min-height: 52px; pointer-events: none; }
  .main.own-title-bar:not(.has-split) .title.bare { pointer-events: auto; right: var(--caption-room); }
  .main.own-title-bar.has-split .title.bare { pointer-events: auto; }
  /* The title stands over the conversation's column (760 px wide, as the composer), as on the Mac. */
  .chatpane > .title:not(.mobile-title) { padding-left: max(var(--space-24), calc((100% - var(--readable-chat)) / 2)); }
  .title .pinned { display: inline-flex; color: var(--text3); }
  .title .name { font: var(--text-title); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .page-title { border-bottom: 1px solid var(--border); }
  .route-body { flex: 1; min-height: 0; overflow: hidden; }
  .chatpane :global(.chat) { flex: 1; min-height: 0; }
  @media (min-width: 641px) and (max-width: 860px) {
    .main { grid-template-columns: 56px minmax(0, 1fr); }
    .rail { padding: 0 6px 8px; }
    .head :global(.orb), .head .spacer, .talk { display: none; }
    .footer { flex-direction: column; border-top: 0; }
    .tabbar { flex-direction: column; background: transparent; }
    .tab, .tab.on, .tab:not(.on) { flex: none; width: 36px; height: 36px; padding: 0; }
    .tab.on span { display: none; }
    .side-list { display: none; }
    /* The sidebar as an overlay beside the icon rail, over a soft scrim. */
    .main.overlay::after { content: ""; position: fixed; inset: 0 0 0 56px; background: color-mix(in srgb, var(--ink) 35%, transparent); z-index: 19; animation: fade 160ms ease-out; }
    .main.overlay .side-list { display: flex; position: fixed; z-index: 20; top: 0; bottom: 0; left: 56px; width: 280px; padding: 8px; background: var(--sidebar); border-right: 1px solid var(--border); box-shadow: var(--shadow-popover); animation: slide 180ms ease-out; }
  }
  @keyframes fade { from { opacity: 0; } }
  @keyframes slide { from { transform: translateX(-12px); opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .main.overlay::after, .main.overlay .side-list { animation: none; } }
  .phone-shell { height: 100vh; height: 100dvh; padding: var(--safe-top) var(--safe-right) 0 var(--safe-left); box-sizing: border-box; background: var(--canvas); }
  :global(html.keyboard-open) .phone-shell { padding-bottom: var(--keyboard); }
  .main.mobile { grid-template-columns: minmax(0, 1fr); grid-template-rows: 1fr auto; padding: var(--safe-top) var(--safe-right) 0 var(--safe-left); }
  .main.mobile .rail { flex-direction: row; justify-content: space-around; align-items: center; padding: 4px 8px calc(4px + var(--safe-bottom)); order: 2; gap: 0; border-top: 1px solid var(--border); border-right: 0; }
  .main.mobile .head { display: none; }
  .main.mobile .tabbar { flex: 1; background: transparent; justify-content: space-around; }
  .main.mobile .tab, .main.mobile .tab:not(.on), .main.mobile .tab.on { flex: 1; flex-direction: column; max-width: 96px; min-height: 54px; gap: 4px; padding: 7px 4px; background: transparent; }
  .main.mobile .tab span, .main.mobile .tab.on span { display: inline; font: var(--text-caption); }
  .main.mobile .tab.on { color: var(--paper); }
  .main.mobile .chatlayout:not(.nolist) .chatpane { display: none; }
  .main.mobile .chatlayout:not(.nolist) :global(.list) { border-right: none; }
  .main.mobile .title { min-height: 56px; padding: 8px 12px; }
  :global(html.keyboard-open) .main.mobile { padding-bottom: var(--keyboard); }
  :global(html.keyboard-open) .main.mobile .rail { display: none; }
</style>
