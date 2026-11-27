<script lang="ts">
  import { tip } from "../../components/ui/tip";
  // Accounts & koppelingen: één pagina in één vorm. Een zoekveld met categorieën, wat jou nodig heeft, je koppelingen
  // (één rijvorm voor elke dienst, ook GitLab en je eigen MCP-servers), wat er op dit apparaat is, en één catalogus van
  // alles wat je kunt toevoegen (één kaartvorm, met een label dat zegt hoe: inloggen, een sleutel of MCP).
  // Settings shows it in two parts, as the Mac's `ConnectionsPage`: Chat apps (the chat apps on this device, WhatsApp
  // and the chat helper apps) and Services (everything else), plus the Mac's grouped `AddConnectionSheet` with direct
  // deep-linking to any chat app's setup sheet (`ConnectionsRoute`).
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import {
    connectorsApi, connectorEvents, health, inCategory, matchesQuery, summary,
    type ConnectMethod, type ConnectorInfo, type Overview, type RemoteView, type ServiceView, type WhatsAppView,
  } from "../../lib/connectors";
  import { events } from "../../lib/api";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import HealthPill from "../connectors/HealthPill.svelte";
  import ServiceSheet from "../connectors/ServiceSheet.svelte";
  import McpServers from "../connectors/McpServers.svelte";
  import McpAddSheet, { presets, type Preset } from "../connectors/McpAddSheet.svelte";
  import WhatsApp from "../connectors/WhatsApp.svelte";
  import CatalogueCard from "../connectors/CatalogueCard.svelte";
  import CategoryChips from "../connectors/CategoryChips.svelte";
  import GitLabRow from "../connectors/GitLabRow.svelte";
  import GitLabSheet from "../connectors/GitLabSheet.svelte";
  import MailAccounts from "../connectors/MailAccounts.svelte";
  import BeeperImportSection from "../connectors/BeeperImportSection.svelte";
  import ChatOptions from "../connectors/ChatOptions.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import Spinner from "../../components/ui/Spinner.svelte";
  import QRCodeView from "../../components/ui/QRCodeView.svelte";
  import { services, type ServicePrefs } from "../../lib/services";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import SettingsTile from "./SettingsTile.svelte";
  import ConnectMethodBadge from "./ConnectMethodBadge.svelte";

  type AddGroup = "mail" | "chats" | "workCode" | "mcp" | "custom";

  interface ChatAppMeta {
    id: string;
    name: string;
    domain: string;
    detail: () => string;
  }

  interface ChatLinkAccount {
    id: string;
    login: string | null;
    name: string;
    isConnected: boolean;
    status: string | null;
  }

  interface ChatLinkNetwork {
    id: string;
    app: string;
    name: string;
    canLink: boolean;
    accounts: ChatLinkAccount[];
  }

  interface ChatLinkField {
    id: string;
    label: string;
    placeholder: string;
    initial: string;
    isSecret: boolean;
    isOptional: boolean;
  }

  type ChatLinkDisplay =
    | { type: "qr"; value: string }
    | { type: "code"; value: string }
    | { type: "image"; value: string }
    | { type: "nothing" };

  type ChatLinkStep =
    | { kind: "input"; id: string; instructions: string; fields: ChatLinkField[] }
    | { kind: "browser"; id: string; instructions: string; url: string }
    | { kind: "display"; id: string; instructions: string; show: ChatLinkDisplay }
    | { kind: "complete"; instructions: string };

  interface ChatLinkSession {
    id: string;
    network: string;
    state: "waitingForInput" | "waitingForCookies" | "waitingForDisplay" | "complete" | "cancelled" | "failed";
    step: ChatLinkStep | null;
    problem: string | null;
  }

  type AddOptionAction =
    | { kind: "mail"; provider: "microsoft" | "google" }
    | { kind: "chat"; app: string }
    | { kind: "github"; service: ServiceView }
    | { kind: "remote"; remote: RemoteView; keyAlternative?: ServiceView }
    | { kind: "service"; service: ServiceView }
    | { kind: "gitlab" }
    | { kind: "mcpPreset"; preset: Preset }
    | { kind: "customMcp" };

  interface AddOption {
    id: string;
    group: AddGroup;
    title: string;
    detail: string;
    domain: string | null;
    method: ConnectMethod;
    linked: boolean;
    disabled?: boolean;
    action: AddOptionAction;
  }

  const CHAT_CATALOG: ChatAppMeta[] = [
    { id: "whatsapp", name: "WhatsApp", domain: "whatsapp.com", detail: () => tr("Nieuwe berichten lezen en antwoorden via een gekoppeld apparaat", "Read new messages and reply via a linked device") },
    { id: "telegram", name: "Telegram", domain: "telegram.org", detail: () => tr("Persoonlijke chats, groepen en kanalen in Nook", "Direct chats, groups and channels in Nook") },
    { id: "signal", name: "Signal", domain: "signal.org", detail: () => tr("Versleutelde chats via je gekoppelde Signal-account", "Encrypted chats through your linked Signal account") },
    { id: "slack", name: "Slack", domain: "slack.com", detail: () => tr("Werkruimtes, kanalen en directe berichten", "Workspaces, channels and direct messages") },
    { id: "teams", name: "Teams", domain: "teams.microsoft.com", detail: () => tr("Microsoft Teams-chats en groepsgesprekken", "Microsoft Teams chats and group conversations") },
    { id: "discord", name: "Discord", domain: "discord.com", detail: () => tr("Directe berichten en serverkanalen", "Direct messages and server channels") },
    { id: "messenger", name: "Messenger", domain: "messenger.com", detail: () => tr("Facebook Messenger-gesprekken in je inbox", "Facebook Messenger conversations in your inbox") },
    { id: "instagram", name: "Instagram", domain: "instagram.com", detail: () => tr("Instagram-berichten direct in Nook", "Instagram direct messages in Nook") },
    { id: "linkedin", name: "LinkedIn", domain: "linkedin.com", detail: () => tr("LinkedIn-berichten lezen en beantwoorden", "Read and reply to LinkedIn messages") },
    { id: "x", name: "X", domain: "x.com", detail: () => tr("Directe berichten van X", "Direct messages from X") },
    { id: "googlechat", name: "Google Chat", domain: "chat.google.com", detail: () => tr("Google Workspace-chats en ruimtes", "Google Workspace chats and spaces") },
  ];

  const CHAT_ALIASES: Record<string, string> = {
    whatsapp: "whatsapp",
    telegram: "telegram",
    signal: "signal",
    slack: "slack",
    teams: "teams",
    msteams: "teams",
    discord: "discord",
    messenger: "messenger",
    instagram: "instagram",
    linkedin: "linkedin",
    x: "x",
    twitter: "x",
    googlechat: "googlechat",
    "google chat": "googlechat",
  };

  let {
    part = "services",
    initialChat = null,
    initialAddGroup = null,
  }: {
    part?: "chats" | "services";
    initialChat?: string | null;
    initialAddGroup?: AddGroup | null;
  } = $props();

  let overview = $state<Overview | null>(null);
  let prefs = $state<ServicePrefs | null>(null);
  let whatsappView = $state<WhatsAppView | null>(null);
  let mailAccountCount = $state(0);
  let mailProviders = $state<Set<string>>(new Set());
  let mailHost = $state<HTMLDivElement | null>(null);
  let sheet = $state<ServiceView | null>(null);
  let query = $state("");
  let category = $state<string | null>(null);
  let connecting = $state<string | null>(null);
  let failures = $state<Record<string, string>>({});
  let gitlabSetup = $state(false);
  let mcpAdd = $state<{ preset: Preset | null } | null>(null);

  // Add connection sheet (`AddConnectionSheet` on the Mac): grouped catalog or straight on one chat app's setup sheet.
  let addOpen = $state(false);
  let addGroup = $state<AddGroup | null>(null);
  let addQuery = $state("");
  let chosenChat = $state<string | null>(null);
  let deepLinked = $state(false);

  // Live chat-helper linking state (`chat_link_*` commands).
  let chatNetworks = $state<ChatLinkNetwork[]>([]);
  let chatNetworksError = $state<string | null>(null);
  let chatNetworksLoading = $state(false);
  let linkSession = $state<ChatLinkSession | null>(null);
  let linkValues = $state<Record<string, string>>({});
  let linkBusy = $state(false);
  let linkError = $state<string | null>(null);

  // 1Password secret provider (`SecretProvidersSection` / `OnePasswordProvider`, CH-97).
  interface OnePasswordStatus {
    enabled: boolean;
    available: boolean;
    mode: "cli" | "serviceAccount" | "connect";
    cliPath: string | null;
    version: string | null;
    signedIn: boolean;
    account: string | null;
    hasServiceAccount: boolean;
    hasConnect: boolean;
    connectHost: string | null;
    reason: string | null;
  }

  let opStatus = $state<OnePasswordStatus | null>(null);
  let opExpanded = $state(false);
  let opServiceToken = $state("");
  let opConnectHost = $state("");
  let opConnectToken = $state("");
  let opProbeRef = $state("op://Private/Example/password");
  let opProbeResult = $state<{ ok: boolean; text: string } | null>(null);
  let opBusy = $state(false);

  async function loadOnePassword() {
    try {
      const s = await invoke<OnePasswordStatus>("secrets_onepassword_status");
      opStatus = s;
      if (s.connectHost && !opConnectHost) opConnectHost = s.connectHost;
    } catch {
      opStatus = {
        enabled: true,
        available: false,
        mode: "cli",
        cliPath: null,
        version: null,
        signedIn: false,
        account: null,
        hasServiceAccount: false,
        hasConnect: false,
        connectHost: null,
        reason: null,
      };
    }
  }

  async function setOnePasswordEnabled(on: boolean) {
    try {
      await invoke("secret_set", { account: "secrets.onepassword.enabled", value: on ? "true" : "false" });
    } catch {
      // Fallback for preview mode without Tauri backend.
    }
    if (opStatus) opStatus = { ...opStatus, enabled: on };
    await loadOnePassword();
  }

  async function saveOnePasswordServiceToken() {
    opBusy = true;
    opProbeResult = null;
    try {
      await invoke("secret_set", { account: "secrets.onepassword.service_account_token", value: opServiceToken.trim() });
      opServiceToken = "";
      await loadOnePassword();
    } catch (e) {
      opProbeResult = { ok: false, text: String(e) };
    } finally {
      opBusy = false;
    }
  }

  async function saveOnePasswordConnect() {
    opBusy = true;
    opProbeResult = null;
    try {
      await invoke("secret_set", { account: "secrets.onepassword.connect_host", value: opConnectHost.trim() });
      if (opConnectToken.trim()) {
        await invoke("secret_set", { account: "secrets.onepassword.connect_token", value: opConnectToken.trim() });
        opConnectToken = "";
      }
      await loadOnePassword();
    } catch (e) {
      opProbeResult = { ok: false, text: String(e) };
    } finally {
      opBusy = false;
    }
  }

  async function testOnePasswordReference() {
    const ref = opProbeRef.trim();
    if (!ref) return;
    opBusy = true;
    opProbeResult = null;
    try {
      const val = await invoke<string>("secrets_onepassword_resolve", { value: ref });
      const length = val ? val.length : 0;
      opProbeResult = {
        ok: true,
        text: tr("Gelukt ({n} tekens gelezen uit 1Password).", "Resolved ({n} characters read from 1Password).", { n: length }),
      };
    } catch (e) {
      opProbeResult = { ok: false, text: String(e) };
    } finally {
      opBusy = false;
    }
  }

  const ADD_GROUPS = $derived<{ id: AddGroup; title: string }[]>([
    { id: "mail", title: tr("Mail en agenda", "Mail & Calendar") },
    { id: "chats", title: tr("Chat-apps", "Chat apps") },
    { id: "workCode", title: tr("Werk en code", "Work & Code") },
    { id: "mcp", title: tr("MCP-servers", "MCP servers") },
    { id: "custom", title: tr("Eigen koppeling", "Custom") },
  ]);

  function normalizeChatId(raw: string): string | null {
    const key = raw.trim().toLowerCase().replace(/^chat\./, "");
    return CHAT_ALIASES[key] ?? null;
  }

  function parseGroup(raw: string | null | undefined): AddGroup | null {
    if (!raw) return null;
    const key = raw.trim().toLowerCase();
    if (key === "mail" || key === "calendar") return "mail";
    if (key === "chats" || key === "chat") return "chats";
    if (key === "workcode" || key === "work" || key === "code" || key === "development" || key === "business") return "workCode";
    if (key === "mcp") return "mcp";
    if (key === "custom" || key === "automation") return "custom";
    return null;
  }

  function openAddSheet(group: AddGroup | null = null) {
    addGroup = group;
    addQuery = "";
    chosenChat = null;
    deepLinked = false;
    linkSession = null;
    linkError = null;
    addOpen = true;
    loadChatNetworks();
  }

  function openChatSetup(appId: string, direct = false) {
    const normalized = normalizeChatId(appId) ?? appId.trim().toLowerCase();
    addGroup = "chats";
    addQuery = "";
    chosenChat = normalized;
    deepLinked = direct;
    linkSession = null;
    linkValues = {};
    linkError = null;
    addOpen = true;
    loadChatNetworks();
  }

  async function closeAddSheet() {
    if (linkSession && !["complete", "cancelled", "failed"].includes(linkSession.state)) {
      invoke("chat_link_cancel", { network: linkSession.network, session: linkSession.id }).catch(() => {});
    }
    addOpen = false;
    chosenChat = null;
    deepLinked = false;
    linkSession = null;
    linkError = null;
    await load();
  }

  function applyRouteString(raw: string | null | undefined): boolean {
    if (!raw) return false;
    const text = raw.trim();
    if (!text) return false;
    if (text.startsWith("{")) {
      try {
        const parsed = JSON.parse(text) as { kind?: string; app?: string; group?: string; category?: string };
        if (parsed.kind === "chat" && parsed.app) {
          openChatSetup(parsed.app, true);
          return true;
        }
        if (parsed.kind === "add") {
          openAddSheet(parseGroup(parsed.group ?? parsed.category));
          return true;
        }
      } catch {
        // Ignore malformed route JSON.
      }
      return false;
    }
    const lower = text.toLowerCase();
    for (const prefix of ["settings:chats:", "settings:connections:chat:", "chat-setup:", "chat:", "chat."]) {
      if (lower.startsWith(prefix)) {
        const target = text.slice(prefix.length);
        if (target) {
          openChatSetup(target, true);
          return true;
        }
      }
    }
    if (lower === "settings:connections:add" || lower === "add") {
      openAddSheet(null);
      return true;
    }
    for (const prefix of ["settings:connections:add:", "add:"]) {
      if (lower.startsWith(prefix)) {
        openAddSheet(parseGroup(text.slice(prefix.length)));
        return true;
      }
    }
    return false;
  }

  function consumePendingRoute() {
    try {
      const pending = localStorage.getItem("settings.connections.route");
      if (pending) {
        localStorage.removeItem("settings.connections.route");
        if (applyRouteString(pending)) return;
      }
      const chatApp = localStorage.getItem("settings.chat.app");
      if (chatApp) {
        localStorage.removeItem("settings.chat.app");
        openChatSetup(chatApp, true);
        return;
      }
    } catch {
      // Storage may be unavailable in restricted contexts.
    }
    if (typeof window !== "undefined") {
      const params = new URLSearchParams(window.location.search);
      const chatParam = params.get("chat");
      if (chatParam) {
        openChatSetup(chatParam, true);
        return;
      }
      const hash = window.location.hash.replace(/^#/, "");
      if (hash.startsWith("chat=")) {
        openChatSetup(decodeURIComponent(hash.slice(5)), true);
      }
    }
  }

  async function loadChatNetworks() {
    chatNetworksLoading = true;
    chatNetworksError = null;
    try {
      const list = await invoke<ChatLinkNetwork[]>("chat_link_networks");
      chatNetworks = Array.isArray(list) ? list : [];
    } catch (e) {
      chatNetworksError = String(e);
    } finally {
      chatNetworksLoading = false;
    }
  }

  async function load() {
    overview = await connectorsApi.overview();
    connectorsApi.whatsapp().then((v) => (whatsappView = v)).catch(() => {});
    loadOnePassword();
    invoke<{ accounts: { provider: string }[] }>("mail_accounts_list")
      .then((m) => {
        mailAccountCount = m?.accounts?.length ?? 0;
        mailProviders = new Set((m?.accounts ?? []).map((a) => a.provider));
      })
      .catch(() => {});
  }

  $effect(() => {
    load();
    loadChatNetworks();
    if (part === "services" && nook.info?.capabilities.desktop) {
      services.prefs().then((p) => (prefs = p)).catch(() => {});
    }
    if (initialChat) openChatSetup(initialChat, true);
    else if (initialAddGroup) openAddSheet(initialAddGroup);
    else consumePendingRoute();

    const unChanged = connectorEvents.onChanged(load);
    const unNav = events.onNavigate((r) => {
      if (!applyRouteString(r)) consumePendingRoute();
    });
    const unLink = listen<ChatLinkSession | null>("chat-link-changed", (e) => {
      if (e.payload) {
        linkSession = e.payload;
        if (e.payload.state === "complete") loadChatNetworks();
      } else {
        linkSession = null;
      }
      linkBusy = false;
    });
    const onCustomRoute = (ev: Event) => {
      const detail = (ev as CustomEvent<{ kind?: string; app?: string; group?: AddGroup | null }>).detail;
      if (!detail) return;
      if (detail.kind === "chat" && detail.app) openChatSetup(detail.app, true);
      else if (detail.kind === "add") openAddSheet(detail.group ?? null);
    };
    window.addEventListener("nook:connections-route", onCustomRoute);
    return () => {
      unChanged.then((f) => f());
      unNav.then((f) => f());
      unLink.then((f) => f());
      window.removeEventListener("nook:connections-route", onCustomRoute);
    };
  });

  // Poll chat_link_session while waiting on a QR / code display step.
  $effect(() => {
    const sess = linkSession;
    if (!addOpen || !chosenChat || !sess || sess.state !== "waitingForDisplay") return;
    const timer = setInterval(async () => {
      try {
        const next = await invoke<ChatLinkSession>("chat_link_session", { network: sess.network, session: sess.id });
        linkSession = next;
        if (next.state === "complete") loadChatNetworks();
      } catch {
        // Keep trying while the sheet stays open.
      }
    }, 2000);
    return () => clearInterval(timer);
  });

  async function setOnlineLyrics(on: boolean) {
    if (!prefs) return;
    prefs = { ...prefs, onlineLyrics: on };
    prefs = await services.savePrefs($state.snapshot(prefs)).catch(() => prefs);
  }

  const byId = $derived(new Map((overview?.connectors ?? []).map((c) => [c.id, c])));
  const remoteInfo = (r: RemoteView): ConnectorInfo | undefined => (r.server ? byId.get(`mcp.${r.server}`) : undefined);
  const shows = (cat: string, text: string) => inCategory(category, cat) && matchesQuery(query, text);
  const serviceText = (s: ServiceView) => `${s.title} ${s.tagline} ${s.capabilities}`;
  const remoteIds = $derived(new Set((overview?.remote ?? []).map((r) => r.id)));

  // Yours: every connected service, whatever way it was connected.
  const linkedServices = $derived((overview?.services ?? []).filter((s) => byId.get(s.id)?.configured && shows(s.category, serviceText(s))));
  const linkedRemote = $derived((overview?.remote ?? []).filter((r) => r.server && connecting !== r.id && shows(r.category, `${r.name} ${r.tagline}`)));
  const gitlabHosts = $derived(shows("development", "GitLab merge requests") ? (overview?.gitlab ?? []) : []);
  const ownServers = $derived(
    (overview?.mcp ?? []).filter((s) => !s.config.serviceId && shows("automation", `${s.config.name} ${s.target} MCP`)),
  );
  const serviceNeedsYou = (s: ServiceView) => health(byId.get(s.id)) === "needsYou";
  const remoteNeedsYou = (r: RemoteView) => health(remoteInfo(r)) === "needsYou";
  const needsYou = $derived(linkedServices.some(serviceNeedsYou) || linkedRemote.some(remoteNeedsYou));
  const hasYours = $derived(linkedServices.length + linkedRemote.length + gitlabHosts.length + ownServers.length > 0);

  // The inline catalogue on Services: everything you can add, sign-in first because that is the easiest.
  const github = $derived(
    (overview?.services ?? []).find((s) => s.id === "github" && !byId.get(s.id)?.configured && shows(s.category, serviceText(s))),
  );
  const oneClick = $derived(
    (overview?.remote ?? []).filter((r) => (!r.server || connecting === r.id) && !byId.get(r.id)?.configured && shows(r.category, `${r.name} ${r.tagline}`)),
  );
  const withKey = $derived(
    (overview?.services ?? []).filter((s) => !byId.get(s.id)?.configured && s.id !== "github" && !remoteIds.has(s.id) && shows(s.category, serviceText(s))),
  );
  const showGitlab = $derived(!(overview?.gitlab ?? []).length && shows("development", "GitLab merge requests"));
  const shownPresets = $derived(presets.filter((p) => shows(p.category, `${p.name} ${p.detail} MCP`)));
  const showCustomMcp = $derived(shows("automation", tr("Zelf een andere MCP-server toevoegen", "Add another MCP server yourself") + " MCP"));
  const hasCatalogue = $derived(!!github || oneClick.length + withKey.length + shownPresets.length > 0 || showGitlab || showCustomMcp);

  // On this device: WhatsApp live, and what the Mac can that this platform cannot.
  const local = $derived((overview?.local ?? []).filter((l) => shows("local", `${l.title} ${l.reason}`)));
  const showMusic = $derived(!!prefs && shows("local", `${tr("Muziek", "Music")} ${tr("Songteksten online opzoeken", "Look up lyrics online")} lrclib.net`));

  // Chat-helper networks indexed by normalized app id.
  const networkByApp = $derived(new Map(chatNetworks.map((n) => [n.app.toLowerCase(), n])));
  const otherChatApps = $derived(CHAT_CATALOG.filter((c) => c.id !== "whatsapp"));
  const isChatLinked = (id: string) => {
    if (id === "whatsapp") return whatsappView?.link.kind === "connected" || !!whatsappView?.settings.enabled;
    const net = networkByApp.get(id);
    return !!net && net.accounts.length > 0;
  };

  // All options for the grouped "Add a connection" sheet (`ConnectionCatalog` on the Mac).
  const allAddOptions = $derived.by<AddOption[]>(() => {
    const items: AddOption[] = [
      {
        id: "mail.microsoft",
        group: "mail",
        title: tr("Microsoft (Outlook / 365)", "Microsoft (Outlook / 365)"),
        detail: tr("Mail lezen, zoeken, versturen en agenda via Microsoft Graph", "Read, search, send mail and sync calendar via Microsoft Graph"),
        domain: "outlook.com",
        method: "signIn",
        linked: mailProviders.has("microsoft"),
        action: { kind: "mail", provider: "microsoft" },
      },
      {
        id: "mail.google",
        group: "mail",
        title: tr("Google (Gmail & Agenda)", "Google (Gmail & Calendar)"),
        detail: tr("Mail lezen, zoeken, versturen en Google Agenda koppelen", "Read, search, send mail and connect Google Calendar"),
        domain: "gmail.com",
        method: "signIn",
        linked: mailProviders.has("google"),
        action: { kind: "mail", provider: "google" },
      },
    ];

    for (const chat of CHAT_CATALOG) {
      items.push({
        id: `chat.${chat.id}`,
        group: "chats",
        title: chat.name,
        detail: chat.detail(),
        domain: chat.domain,
        method: "signIn",
        linked: isChatLinked(chat.id),
        action: { kind: "chat", app: chat.id },
      });
    }

    if (overview) {
      const gh = overview.services.find((s) => s.id === "github");
      if (gh) {
        items.push({
          id: "service.github",
          group: "workCode",
          title: gh.title,
          detail: gh.tagline,
          domain: gh.domain || "github.com",
          method: "signIn",
          linked: !!byId.get("github")?.configured,
          action: { kind: "github", service: gh },
        });
      }
      for (const r of overview.remote) {
        const keyAlternative = overview.services.find((s) => s.id === r.id);
        const linked = !!r.server || !!byId.get(r.id)?.configured || (r.id === "gitlab" && overview.gitlab.length > 0);
        items.push({
          id: `signin.${r.id}`,
          group: "workCode",
          title: r.name,
          detail: r.tagline,
          domain: r.domain,
          method: "signIn",
          linked,
          disabled: !overview.caps.browserSignIn && !keyAlternative,
          action: { kind: "remote", remote: r, keyAlternative },
        });
      }
      for (const s of overview.services) {
        if (s.id === "github" || remoteIds.has(s.id)) continue;
        items.push({
          id: `service.${s.id}`,
          group: "workCode",
          title: s.title,
          detail: s.tagline,
          domain: s.domain || null,
          method: "key",
          linked: !!byId.get(s.id)?.configured,
          action: { kind: "service", service: s },
        });
      }
      if (!remoteIds.has("gitlab")) {
        items.push({
          id: "service.gitlab",
          group: "workCode",
          title: "GitLab",
          detail: tr("Merge requests op gitlab.com of je eigen host", "Merge requests on gitlab.com or your own host"),
          domain: "gitlab.com",
          method: "key",
          linked: overview.gitlab.length > 0,
          action: { kind: "gitlab" },
        });
      }
    }

    for (const p of presets) {
      items.push({
        id: `mcp.${p.id}`,
        group: "mcp",
        title: p.name,
        detail: p.detail,
        domain: p.domain,
        method: "mcp",
        linked: false,
        disabled: overview ? !overview.caps.stdio : false,
        action: { kind: "mcpPreset", preset: p },
      });
    }

    items.push({
      id: "mcp.custom",
      group: "custom",
      title: tr("Zelf een andere MCP-server toevoegen", "Add another MCP server yourself"),
      detail: tr("Plak een opdracht (npx, uvx), een Claude Desktop JSON-configuratie of een web-adres.", "Paste a command (npx, uvx), a Claude Desktop JSON configuration or a web address."),
      domain: null,
      method: "mcp",
      linked: false,
      action: { kind: "customMcp" },
    });

    return items;
  });

  const filteredAddOptions = $derived.by(() => {
    const q = addQuery.trim().toLowerCase();
    return allAddOptions.filter((opt) => {
      if (addGroup && opt.group !== addGroup) return false;
      if (!q) return true;
      const groupName = ADD_GROUPS.find((g) => g.id === opt.group)?.title ?? "";
      return `${opt.title} ${opt.detail} ${groupName}`.toLowerCase().includes(q);
    });
  });

  const activeChatMeta = $derived(chosenChat ? (CHAT_CATALOG.find((c) => c.id === chosenChat) ?? { id: chosenChat, name: chosenChat, domain: "", detail: () => "" }) : null);
  const activeChatNetwork = $derived(chosenChat ? (networkByApp.get(chosenChat) ?? null) : null);

  async function chooseAddOption(opt: AddOption) {
    switch (opt.action.kind) {
      case "chat":
        chosenChat = opt.action.app;
        linkSession = null;
        linkValues = {};
        linkError = null;
        return;
      case "mail":
        addOpen = false;
        query = "";
        category = null;
        setTimeout(() => {
          mailHost?.scrollIntoView({ behavior: "smooth", block: "center" });
          mailHost?.classList.add("setting-lit");
          setTimeout(() => mailHost?.classList.remove("setting-lit"), 1600);
        }, 50);
        return;
      case "github":
        addOpen = false;
        await signInGithub(opt.action.service);
        return;
      case "remote":
        addOpen = false;
        if (overview?.caps.browserSignIn) {
          await connectRemote(opt.action.remote);
        } else if (opt.action.keyAlternative) {
          sheet = opt.action.keyAlternative;
        }
        return;
      case "service":
        addOpen = false;
        sheet = opt.action.service;
        return;
      case "gitlab":
        addOpen = false;
        gitlabSetup = true;
        return;
      case "mcpPreset":
        addOpen = false;
        mcpAdd = { preset: opt.action.preset };
        return;
      case "customMcp":
        addOpen = false;
        mcpAdd = { preset: null };
        return;
    }
  }

  async function startChatLink(networkId: string) {
    linkBusy = true;
    linkError = null;
    linkValues = {};
    try {
      const sess = await invoke<ChatLinkSession>("chat_link_start", { network: networkId });
      linkSession = sess;
      if (sess.step?.kind === "input") {
        const defaults: Record<string, string> = {};
        for (const f of sess.step.fields) defaults[f.id] = f.initial ?? "";
        linkValues = defaults;
      }
      if (sess.state === "complete") await loadChatNetworks();
    } catch (e) {
      linkError = String(e);
    } finally {
      linkBusy = false;
    }
  }

  async function submitChatLinkInput() {
    if (!linkSession) return;
    linkBusy = true;
    linkError = null;
    try {
      const next = await invoke<ChatLinkSession>("chat_link_submit", {
        network: linkSession.network,
        session: linkSession.id,
        values: linkValues,
      });
      linkSession = next;
      if (next.step?.kind === "input") {
        const defaults: Record<string, string> = {};
        for (const f of next.step.fields) defaults[f.id] = f.initial ?? "";
        linkValues = defaults;
      }
      if (next.state === "complete") await loadChatNetworks();
    } catch (e) {
      linkError = String(e);
    } finally {
      linkBusy = false;
    }
  }

  async function openChatSignInWindow() {
    if (!linkSession || !activeChatMeta) return;
    linkBusy = true;
    linkError = null;
    try {
      await invoke("chat_link_sign_in", {
        network: linkSession.network,
        session: linkSession.id,
        name: activeChatMeta.name,
      });
    } catch (e) {
      linkError = String(e);
      linkBusy = false;
    }
  }

  async function cancelChatLink() {
    if (!linkSession) return;
    const sess = linkSession;
    linkSession = null;
    linkBusy = false;
    linkError = null;
    await invoke("chat_link_cancel", { network: sess.network, session: sess.id }).catch(() => {});
  }

  async function removeChatAccount(networkId: string, login: string) {
    linkError = null;
    try {
      await invoke("chat_link_remove", { network: networkId, login });
      await loadChatNetworks();
    } catch (e) {
      linkError = String(e);
    }
  }

  async function toggle(id: string, on: boolean) {
    await connectorsApi.toggle(id, on);
    await load();
  }

  async function connectRemote(r: RemoteView) {
    connecting = r.id;
    delete failures[r.id];
    try {
      await connectorsApi.mcpConnectService(r.id);
    } catch (e) {
      failures[r.id] = String(e);
    }
    connecting = null;
    await load();
  }

  async function disconnectRemote(r: RemoteView) {
    if (r.server) await connectorsApi.mcpRemove(r.server);
    await load();
  }

  /** GitHub signs in too: its own login (device flow, in the sheet that shows the code) or the GitHub CLI login. */
  async function signInGithub(s: ServiceView) {
    if (!overview?.caps.ghCli || overview.caps.deviceFlow) {
      sheet = s;
      return;
    }
    connecting = "github";
    delete failures.github;
    try {
      await connectorsApi.githubCli("github");
    } catch (e) {
      failures.github = String(e);
    }
    connecting = null;
    await load();
  }

  /** "Herstel" repairs by signing in again where it can, never via a new key: GitHub's login (or the gh login), or the
   *  service's own sign-in page (Notion, Stripe, Vercel). Otherwise the sheet explains what is wrong. */
  async function repair(s: ServiceView) {
    const h = health(byId.get(s.id));
    if (s.id === "github" && h === "needsYou") {
      await signInGithub(s);
      if (failures.github) sheet = s;
      return;
    }
    if (h === "needsYou" && remoteIds.has(s.id) && overview?.caps.browserSignIn) {
      connecting = s.id;
      delete failures[s.id];
      try {
        await connectorsApi.repairBySignIn(s.id);
      } catch (e) {
        failures[s.id] = String(e);
      }
      connecting = null;
      await load();
      return;
    }
    sheet = s;
  }

  function serviceDetail(s: ServiceView, info: ConnectorInfo | undefined): string {
    if (connecting === s.id) return s.id === "github" ? tr("Nook neemt je GitHub-login over…", "Nook is taking over your GitHub login…") : tr("Log in bij {name} in het venster dat net openging. Nook gaat daarna vanzelf verder.", "Sign in to {name} in the window that just opened. Nook carries on by itself after that.", { name: s.title });
    return failures[s.id] ?? summary(info, s.tagline);
  }
</script>


{#if part === "chats"}
  <div class="section-head">
    <h3>{tr("Chat-apps", "Chat apps")}</h3>
    <button type="button" class="head-action" onclick={() => openAddSheet("chats")}>
      <Ico name="plus" size={14} />{tr("Chat-app toevoegen", "Add a chat app")}
    </button>
  </div>
  <WhatsApp />

  <h3>{tr("Meer chat-apps", "More chat apps")}</h3>
  <p class="section-info">{tr("Koppel Telegram, Signal, Slack, Teams, Discord en meer om berichten in Nook te lezen en te beantwoorden.", "Connect Telegram, Signal, Slack, Teams, Discord and more to read and answer messages in Nook.")}</p>
  <div class="group catalogue">
    <div class="cards">
      {#each otherChatApps as chat (chat.id)}
        {@const net = networkByApp.get(chat.id)}
        {@const linked = !!net && net.accounts.length > 0}
        <CatalogueCard
          title={chat.name}
          domain={chat.domain}
          method="signIn"
          badge={linked ? tr("Gekoppeld", "Linked") : undefined}
          detail={linked && net ? net.accounts.map((a) => a.name).join(", ") : chat.detail()}
          onclick={() => openChatSetup(chat.id, true)}
        />
      {/each}
    </div>
  </div>
  <BeeperImportSection {isChatLinked} onOpenChatApp={(app) => openChatSetup(app, true)} />
  <ChatOptions />
{:else if overview}
  <label class="search-card conn-search">
    <Ico name="search" size={13} />
    <input placeholder={tr("Zoek in je koppelingen", "Search your connections")} aria-label={tr("Zoek een koppeling of wat hij kan", "Search for a connection or what it can do")} bind:value={query} />
    {#if query}
      <button type="button" class="clear" onclick={() => (query = "")} aria-label={tr("Wissen", "Clear")}><Ico name="circle-x" size={14} /></button>
    {/if}
  </label>
  <CategoryChips bind:selected={category} />

  {#if needsYou}
    <h3>{tr("Heeft jou nodig", "Needs you")}</h3>
    <div class="group">
      {#each linkedServices.filter(serviceNeedsYou) as s (s.id)}{@render serviceRow(s)}{/each}
      {#each linkedRemote.filter(remoteNeedsYou) as r (r.id)}{@render remoteRow(r)}{/each}
    </div>
  {/if}

  {#if hasYours && (linkedServices.some((s) => !serviceNeedsYou(s)) || linkedRemote.some((r) => !remoteNeedsYou(r)) || gitlabHosts.length || ownServers.length)}
    <div class="section-head">
      <h3>{tr("Jouw koppelingen", "Your connections")}</h3>
      <button type="button" class="head-action" onclick={() => openAddSheet(null)}>
        <Ico name="plus" size={14} />{tr("Koppeling toevoegen", "Add a connection")}
      </button>
    </div>
    <div class="group">
      {#each linkedServices.filter((s) => !serviceNeedsYou(s)) as s (s.id)}{@render serviceRow(s)}{/each}
      {#each linkedRemote.filter((r) => !remoteNeedsYou(r)) as r (r.id)}{@render remoteRow(r)}{/each}
      {#each gitlabHosts as host (host)}<GitLabRow {host} onchange={load} />{/each}
      <McpServers servers={ownServers} connectors={overview.connectors} onchange={load} />
    </div>
  {:else}
    <!-- Keep the heading discoverable for Settings search and offer the Mac's "+ Add a connection" button on top. -->
    <div class="section-head">
      <h3>{tr("Jouw koppelingen", "Your connections")}</h3>
      <button type="button" class="head-action" onclick={() => openAddSheet(null)}>
        <Ico name="plus" size={14} />{tr("Koppeling toevoegen", "Add a connection")}
      </button>
    </div>
    {#if !mailAccountCount && !query.trim() && category === null}
      <div class="group">
        <p class="empty-note">{tr("Nog geen diensten gekoppeld. Klik op “Koppeling toevoegen” of kies er hieronder een.", "No services linked yet. Click “Add a connection” or pick one below.")}</p>
      </div>
    {/if}
  {/if}

  <div bind:this={mailHost}>
    <MailAccounts {query} {category} onchange={load} />
  </div>

  {#if local.length}
    <h3>{tr("Op dit apparaat", "On this device")}</h3>
    <div class="group">
      {#each local as l (l.id)}
        <div class="row local"><span><strong>{l.title}</strong> <span class="mark">—</span><br /><span class="faint small">{l.reason}</span></span></div>
      {/each}
    </div>
    <p class="note">{tr("Bestanden en het klembord leest Nook met de onderdelen van dit platform zelf; die staan bij hun eigen instellingen.", "Nook reads files and the clipboard with this platform's own parts; they have their own settings.")}</p>
  {/if}

  {#if hasCatalogue}
    {@const nothingYet = !hasYours && !query.trim() && category === null}
    <!-- With nothing linked, the Mac's Services card: what to do first, and the services to pick from in the same card. -->
    <div class="section-head">
      <h3>{nothingYet ? tr("Diensten", "Services") : tr("Dienst toevoegen", "Add a service")}</h3>
      <button type="button" class="head-action" onclick={() => openAddSheet(null)}>
        <Ico name="plus" size={14} />{tr("Alles bekijken", "Browse all")}
      </button>
    </div>
    <div class="group catalogue">
    {#if nothingYet}
      <div class="nothing">
        <strong>{tr("Nog niets gekoppeld", "Nothing linked yet")}</strong>
        <span>{tr("Koppel de diensten die je gebruikt, dan kan Nook meelezen en helpen. Kies er hieronder een. Chat-apps koppel je onder Chat-apps.", "Link the services you use, and Nook can read along and help. Pick one below. Chat apps are linked under Chat apps.")}</span>
      </div>
    {/if}
    <div class="cards">
      {#if github}
        {@const gh = github}
        <CatalogueCard
          title={gh.title}
          domain={gh.domain || null}
          method="signIn"
          detail={connecting === "github" ? tr("Nook neemt je GitHub-login over…", "Nook is taking over your GitHub login…") : (failures.github ?? gh.tagline)}
          bad={!!failures.github}
          badge={failures.github ? tr("Opnieuw proberen", "Try again") : undefined}
          busy={connecting === "github"}
          help={tr("Log in bij {name}, zonder eerst een token te maken", "Sign in to {name} without making a token first", { name: gh.title })}
          onclick={() => signInGithub(gh)}
          alt={{ label: tr("Met een token", "With a token"), help: tr("Liever zelf een token plakken", "Rather paste a token yourself"), onclick: () => (sheet = gh) }}
        />
      {/if}
      {#each oneClick as r (r.id)}
        {@const keyAlternative = overview.services.find((s) => s.id === r.id)}
        <CatalogueCard
          title={r.name}
          domain={r.domain}
          method="signIn"
          detail={failures[r.id] ?? (connecting === r.id ? tr("Log in bij {name} in het venster dat net openging. Nook gaat daarna vanzelf verder.", "Sign in to {name} in the window that just opened. Nook carries on by itself after that.", { name: r.name }) : r.tagline)}
          bad={!!failures[r.id]}
          badge={failures[r.id] ? tr("Opnieuw proberen", "Try again") : undefined}
          busy={connecting === r.id}
          disabled={!overview.caps.browserSignIn || connecting === r.id}
          help={overview.caps.browserSignIn ? tr("Log in bij {name} op zijn eigen site", "Sign in to {name} on its own site", { name: r.name }) : tr("Inloggen via de browser kan op Android nog niet.", "Signing in through the browser doesn't work on Android yet.")}
          onclick={() => connectRemote(r)}
          alt={keyAlternative ? { label: tr("Met sleutel", "With a key"), help: tr("Liever een API-sleutel plakken dan inloggen", "Rather paste an API key than sign in"), onclick: () => (sheet = keyAlternative) } : undefined}
        />
      {/each}
      {#each withKey as s (s.id)}
        <CatalogueCard title={s.title} domain={s.domain || null} method="key" detail={s.tagline} help={tr("Koppel {name} met een sleutel, stap voor stap", "Connect {name} with a key, step by step", { name: s.title })} onclick={() => (sheet = s)} />
      {/each}
      {#if showGitlab}
        <CatalogueCard title="GitLab" domain="gitlab.com" method="key" detail={tr("Merge requests op gitlab.com of je eigen host", "Merge requests on gitlab.com or your own host")} onclick={() => (gitlabSetup = true)} />
      {/if}
      {#each shownPresets as p (p.id)}
        <CatalogueCard
          title={p.name}
          domain={p.domain}
          method="mcp"
          detail={p.detail}
          disabled={!overview.caps.stdio}
          help={overview.caps.stdio ? undefined : tr("Op Android kan Nook geen programma's starten: alleen servers met een https-adres werken hier.", "On Android Nook can't start programs: only servers with an https address work here.")}
          onclick={() => (mcpAdd = { preset: p })}
        />
      {/each}
      {#if showCustomMcp}
        <CatalogueCard
          title={tr("Zelf een andere MCP-server toevoegen", "Add another MCP server yourself")}
          method="mcp"
          detail={tr("Plak een opdracht (npx, uvx), een Claude Desktop JSON-configuratie of een web-adres.", "Paste a command (npx, uvx), a Claude Desktop JSON configuration or a web address.")}
          onclick={() => (mcpAdd = { preset: null })}
        />
      {/if}
    </div>
    </div>
    <p class="note">{tr("Eén kaart, één klik. Inloggen gebeurt op de site van de dienst zelf; bij een sleutel laat Nook stap voor stap zien waar je die vindt; MCP koppelt elk ander programma. Tools van een MCP-server die alleen lezen gebruikt Nook bij een antwoord; al het andere wordt een actie die pas na jouw Uitvoeren gebeurt.", "One card, one click. Signing in happens on the service's own site; for a key Nook shows step by step where to find it; MCP connects any other program. Read-only tools from an MCP server are used in an answer; everything else becomes an action that only happens after you press Run.")}</p>
  {:else if !hasYours && !local.length && !showMusic}
    <p class="faint empty">{tr("Niets gevonden voor “{query}”. Probeer een andere naam, of voeg het als MCP-server toe.", "Nothing found for “{query}”. Try another name, or add it as an MCP server.", { query: query.trim() })}</p>
  {/if}

  {#if showMusic && prefs}
    <h3>{tr("Muziek", "Music")}</h3>
    <div class="group">
      <label class="row">
        <span>{tr("Songteksten online opzoeken", "Look up lyrics online")}<br /><small>{tr("De muziek-tab zoekt songteksten op lrclib.net. Alleen de titel, artiest, het album en de lengte van het spelende nummer worden verstuurd.", "The Music tab finds lyrics on lrclib.net. Only the title, artist, album and length of the playing track are sent.")}</small></span>
        <input type="checkbox" role="switch" checked={!!prefs.onlineLyrics} onchange={(e) => setOnlineLyrics(e.currentTarget.checked)} />
      </label>
    </div>
  {/if}
{/if}

{#snippet serviceRow(s: ServiceView)}
  {@const info = byId.get(s.id)}
  {@const h = health(info)}
  <div class="row">
    <button class="plain" onclick={() => (sheet = s)} title={tr("Klik om {name} te beheren", "Click to manage {name}", { name: s.title })}>
      <ServiceIcon domain={s.domain || null} title={s.title} />
      <span class="text">
        <span>{s.title}{#if s.accounts.filter((a) => a.hasToken).length > 1}<span class="faint"> · {tr("{n} accounts", "{n} accounts", { n: s.accounts.filter((a) => a.hasToken).length })}</span>{/if}</span>
        <span class="faint small" class:bad={h === "broken" || !!failures[s.id]}>{serviceDetail(s, info)}</span>
      </span>
    </button>
    {#if connecting === s.id}
      <span class="spin" aria-label={tr("Bezig", "Working")}></span>
    {:else if h === "broken" || h === "needsYou"}
      <button class="fix" class:broken={h === "broken"} onclick={() => repair(s)}>{tr("Herstel", "Fix")}</button>
    {:else}
      <HealthPill health={h} />
    {/if}
    <input type="checkbox" role="switch" checked={info?.on ?? true} use:tip={tr("Zet deze koppeling aan of uit", "Turn this connection on or off")} onchange={(e) => toggle(s.id, e.currentTarget.checked)} />
  </div>
{/snippet}

{#snippet remoteRow(r: RemoteView)}
  {@const info = remoteInfo(r)}
  {@const h = health(info)}
  <div class="row">
    <span class="plain">
      <ServiceIcon domain={r.domain} title={r.name} />
      <span class="text">
        <span>{r.name} <span class="faint small">· {tr("ingelogd", "signed in")}</span></span>
        <span class="faint small">{h === "needsYou" ? tr("Log opnieuw in bij {name}, dan kan Nook er weer bij.", "Sign in to {name} again so Nook can reach it.", { name: r.name }) : summary(info, r.tagline)}</span>
      </span>
    </span>
    {#if h === "needsYou"}<button class="fix" onclick={() => r.server && connectorsApi.mcpSignIn(r.server).then(load)}>{tr("Opnieuw autoriseren", "Authorize again")}</button>{:else}<HealthPill health={h} />{/if}
    <button class="ghost danger" onclick={() => disconnectRemote(r)} title={tr("Nook vraagt {name} de toegang in te trekken en verwijdert de sleutels uit je kluis.", "Nook asks {name} to revoke access and removes the keys from your keychain.", { name: r.name })}>{tr("Ontkoppel", "Disconnect")}</button>
  </div>
{/snippet}

{#if addOpen}
  <Sheet onclose={closeAddSheet} label={chosenChat && activeChatMeta ? activeChatMeta.name : tr("Koppeling toevoegen", "Add a connection")}>
    <div class="add-sheet">
      {#if chosenChat && activeChatMeta}
        <div class="add-head">
          {#if !deepLinked}
            <button type="button" class="back-btn ghost" onclick={() => { cancelChatLink(); chosenChat = null; }}>
              <Ico name="chevron-left" size={14} />{tr("Terug", "Back")}
            </button>
          {/if}
          <div class="chat-title-row">
            <ServiceIcon domain={activeChatMeta.domain || null} title={activeChatMeta.name} size={32} />
            <div class="text">
              <strong>{activeChatMeta.name}</strong>
              <span class="faint small">{activeChatMeta.detail()}</span>
            </div>
          </div>
        </div>

        <div class="add-body">
          {#if chosenChat === "whatsapp"}
            <WhatsApp />
          {:else if chatNetworksLoading && !activeChatNetwork}
            <div class="inline"><Spinner size={14} /><span class="faint small">{tr("Beschikbare chatkoppelingen laden…", "Loading available chat connections…")}</span></div>
          {:else if activeChatNetwork}
            {@const net = activeChatNetwork}
            {#if net.accounts.length}
              <div class="group">
                {#each net.accounts as acc (acc.id)}
                  <div class="row">
                    <span class="text">
                      <span>{acc.name}</span>
                      <span class="faint small">{acc.isConnected ? tr("Verbonden", "Connected") : (acc.status ?? tr("Niet verbonden", "Not connected"))}</span>
                    </span>
                    {#if acc.login}
                      <button type="button" class="ghost danger small-btn" onclick={() => removeChatAccount(net.id, acc.login!)}>{tr("Ontkoppel", "Disconnect")}</button>
                    {/if}
                  </div>
                {/each}
              </div>
            {/if}

            {#if linkSession}
              <div class="link-box">
                {#if linkSession.state === "complete" || linkSession.step?.kind === "complete"}
                  <div class="inline ok-line">
                    <Ico name="circle-check" size={16} />
                    <span>{linkSession.step?.kind === "complete" && linkSession.step.instructions ? linkSession.step.instructions : tr("{name} is gekoppeld.", "{name} is connected.", { name: activeChatMeta.name })}</span>
                  </div>
                {:else if linkSession.state === "failed"}
                  <p class="bad small">{linkSession.problem ?? tr("Het koppelen is niet gelukt. Probeer het opnieuw.", "Linking didn't succeed. Please try again.")}</p>
                  <button type="button" class="primary" onclick={() => startChatLink(net.id)}>{tr("Opnieuw proberen", "Try again")}</button>
                {:else if linkSession.step?.kind === "input"}
                  {#if linkSession.step.instructions}<p class="faint small">{linkSession.step.instructions}</p>{/if}
                  {#each linkSession.step.fields as field (field.id)}
                    <label class="field-col">
                      <span class="faint small">{field.label}</span>
                      <input
                        type={field.isSecret ? "password" : "text"}
                        placeholder={field.placeholder}
                        bind:value={linkValues[field.id]}
                        onkeydown={(e) => e.key === "Enter" && submitChatLinkInput()}
                      />
                    </label>
                  {/each}
                  <div class="inline end">
                    <button type="button" class="ghost" onclick={cancelChatLink}>{tr("Annuleer", "Cancel")}</button>
                    <button type="button" class="primary" disabled={linkBusy} onclick={submitChatLinkInput}>
                      {#if linkBusy}<Spinner size={12} />{/if}
                      {tr("Volgende", "Continue")}
                    </button>
                  </div>
                {:else if linkSession.step?.kind === "browser"}
                  <p class="faint small">{linkSession.step.instructions || tr("Log in bij {name} in het aparte inlogvenster. Nook sluit het venster vanzelf zodra je bent ingelogd.", "Sign in to {name} in the separate login window. Nook closes the window automatically once you are signed in.", { name: activeChatMeta.name })}</p>
                  <div class="inline">
                    <button type="button" class="primary" disabled={linkBusy} onclick={openChatSignInWindow}>
                      {#if linkBusy}<Spinner size={12} />{/if}
                      {tr("Open inlogvenster", "Open sign-in window")}
                    </button>
                    <button type="button" class="ghost" onclick={cancelChatLink}>{tr("Annuleer", "Cancel")}</button>
                  </div>
                {:else if linkSession.step?.kind === "display"}
                  {#if linkSession.step.instructions}<p class="faint small">{linkSession.step.instructions}</p>{/if}
                  {#if linkSession.step.show.type === "qr"}
                    <QRCodeView src={linkSession.step.show.value} label={tr("QR-code om {name} te koppelen", "QR code to link {name}", { name: activeChatMeta.name })} size={188} />
                  {:else if linkSession.step.show.type === "code"}
                    <code class="link-code">{linkSession.step.show.value}</code>
                  {:else if linkSession.step.show.type === "image"}
                    <img class="link-img" src={linkSession.step.show.value} alt={activeChatMeta.name} />
                  {/if}
                  <div class="inline">
                    <Spinner size={13} />
                    <span class="faint small">{tr("Wachten op bevestiging…", "Waiting for confirmation…")}</span>
                    <button type="button" class="ghost" onclick={cancelChatLink}>{tr("Annuleer", "Cancel")}</button>
                  </div>
                {/if}
              </div>
            {:else}
              <div class="link-box">
                <p class="faint small">{tr("Koppel je eigen {name}-account lokaal via Nooks chat-helper. Je berichten blijven op deze computer.", "Link your own {name} account locally through Nook's chat helper. Your messages stay on this computer.", { name: activeChatMeta.name })}</p>
                <button type="button" class="primary" disabled={linkBusy || !net.canLink} onclick={() => startChatLink(net.id)}>
                  {#if linkBusy}<Spinner size={12} />{/if}
                  {net.accounts.length ? tr("Extra account koppelen", "Link another account") : tr("{name} koppelen", "Link {name}", { name: activeChatMeta.name })}
                </button>
              </div>
            {/if}
            {#if linkError}<p class="bad small">{linkError}</p>{/if}
          {:else}
            <div class="link-box">
              <p class="faint small">{tr("De chat-helper voor {name} draait nog niet op dit apparaat. Controleer of de chat-helper beschikbaar is of probeer het opnieuw.", "The chat helper for {name} isn't running on this device yet. Check that the chat helper is available or try again.", { name: activeChatMeta.name })}</p>
              {#if chatNetworksError}<p class="bad small">{chatNetworksError}</p>{/if}
              <button type="button" onclick={loadChatNetworks}>{tr("Opnieuw proberen", "Try again")}</button>
            </div>
          {/if}
        </div>
      {:else}
        <div class="add-head">
          <div class="add-head-row">
            <SettingsTile section="connections" size={40} />
            <div class="text">
              <strong>{tr("Koppeling toevoegen", "Add a connection")}</strong>
              <span class="faint small">{tr("Kies een chat-app, e-mail, dienst of eigen MCP-server.", "Pick a chat app, email, service or your own MCP server.")}</span>
            </div>
          </div>
          <label class="search-card add-search">
            <Ico name="search" size={13} />
            <input placeholder={tr("Zoek een koppeling…", "Search connections…")} aria-label={tr("Zoek een koppeling…", "Search connections…")} bind:value={addQuery} />
            {#if addQuery}
              <button type="button" class="clear" onclick={() => (addQuery = "")} aria-label={tr("Wissen", "Clear")}><Ico name="circle-x" size={14} /></button>
            {/if}
          </label>
          <div class="add-chips" role="group" aria-label={tr("Categorie", "Category")}>
            <button type="button" class="chip-btn" class:on={addGroup === null} aria-pressed={addGroup === null} onclick={() => (addGroup = null)}>{tr("Alles", "All")}</button>
            {#each ADD_GROUPS as g (g.id)}
              <button type="button" class="chip-btn" class:on={addGroup === g.id} aria-pressed={addGroup === g.id} onclick={() => (addGroup = g.id)}>{g.title}</button>
            {/each}
          </div>
        </div>

        <div class="add-body">
          {#if filteredAddOptions.length === 0}
            <p class="faint small">{tr("Niets gevonden voor “{query}”.", "Nothing found for “{query}”.", { query: addQuery.trim() })}</p>
          {:else}
            {#each ADD_GROUPS as g (g.id)}
              {@const groupOptions = filteredAddOptions.filter((o) => o.group === g.id)}
              {#if groupOptions.length}
                <div class="add-group">
                  <div class="add-group-title">{g.title}</div>
                  <div class="add-grid">
                    {#each groupOptions as opt (opt.id)}
                      <button type="button" class="opt-tile" disabled={opt.disabled} onclick={() => chooseAddOption(opt)}>
                        <ServiceIcon domain={opt.domain} title={opt.title} size={28} />
                        <span class="text">
                          <span class="opt-name">{opt.title}</span>
                          <span class="faint small">{opt.detail}</span>
                        </span>
                        {#if opt.linked}
                          <span class="linked-mark" aria-label={tr("Gekoppeld", "Linked")}><Ico name="circle-check" size={16} /></span>
                        {:else}
                          <ConnectMethodBadge method={opt.method} />
                        {/if}
                      </button>
                    {/each}
                  </div>
                </div>
              {/if}
            {/each}
          {/if}
        </div>
      {/if}

      <div class="add-foot">
        <button type="button" class="primary" onclick={closeAddSheet}>{tr("Klaar", "Done")}</button>
      </div>
    </div>
  </Sheet>
{/if}

{#if sheet && overview}
  <ServiceSheet service={sheet} info={byId.get(sheet.id)} caps={overview.caps} onclose={() => { sheet = null; load(); }} onchange={load} />
{/if}
{#if gitlabSetup}
  <GitLabSheet onclose={() => { gitlabSetup = false; load(); }} onchange={load} />
{/if}
{#if mcpAdd && overview}
  <McpAddSheet preset={mcpAdd.preset} caps={overview.caps} onclose={() => (mcpAdd = null)} onchange={load} />
{/if}

<style>
  .plain { display: flex; gap: var(--space-12); align-items: center; background: none; border: none; padding: 0; text-align: left; flex: 1; min-width: 0; }
  .plain:hover { background: none; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; flex: 1; }
  .text span:last-child { overflow: hidden; text-overflow: ellipsis; }
  .small { font: var(--text-detail); line-height: 1.3; }
  .small-btn { font: var(--text-label); padding: var(--space-4) var(--space-8); }
  .bad { color: var(--coral); }
  .fix { background: var(--amber); color: var(--ink); border: none; font: var(--text-label); font-weight: 600; padding: var(--space-4) var(--space-12); border-radius: var(--radius-pill); }
  .fix.broken { background: var(--coral); color: var(--paper); }
  .spin { flex: none; width: 12px; height: 12px; border-radius: 50%; border: 1.5px solid var(--text2); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  /* Spacing below the search card before CategoryChips. */
  .conn-search + :global(*) { margin-top: var(--space-12); }
  .empty { margin-top: var(--space-16); }
  /* The catalogue card: "Nothing linked yet" over a line, then the tiles in a grid, 8 px apart. */
  .catalogue { padding: 0; }
  .nothing { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16); border-bottom: 1px solid var(--separator); }
  .nothing strong { font: var(--text-emphasis); color: var(--paper); }
  .nothing span { font: var(--text-body); line-height: 1.4; color: var(--text2); }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: var(--space-8); padding: var(--space-16); }
  .mark { color: var(--text3); }
  .local { justify-content: flex-start; }

  /* Add connection sheet (`AddConnectionSheet` on the Mac). */
  .add-sheet { display: flex; flex-direction: column; max-height: 85vh; min-height: 0; }
  .add-head { display: flex; flex-direction: column; gap: var(--space-12); padding: var(--space-16); border-bottom: 1px solid var(--separator); flex: none; }
  .add-head-row { display: flex; align-items: center; gap: var(--space-12); }
  .add-head strong { font: var(--text-title); color: var(--paper); }
  .add-search { height: 34px; }
  .add-chips { display: flex; gap: var(--space-6); overflow-x: auto; padding: var(--space-2) 0; scrollbar-width: none; }
  .chip-btn { flex: none; padding: var(--space-4) var(--space-12); border: none; border-radius: var(--radius-control); background: var(--smoke); color: var(--text-strong); font: var(--text-label); }
  .chip-btn.on { background: var(--iris); color: var(--on-iris); }
  .add-body { flex: 1; min-height: 0; overflow-y: auto; padding: var(--space-16); display: flex; flex-direction: column; gap: var(--space-16); }
  .add-group { display: flex; flex-direction: column; gap: var(--space-8); }
  .add-group-title { font: var(--text-label); color: var(--text3); }
  .add-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: var(--space-8); }
  .opt-tile { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-12); border: 1px solid var(--separator); border-radius: var(--radius-card); background: var(--surface); text-align: left; width: 100%; }
  .opt-tile:hover:not(:disabled) { background: var(--smoke); }
  .opt-tile:disabled { opacity: 0.5; }
  .opt-name { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .linked-mark { flex: none; color: var(--mint); display: grid; place-items: center; }
  .add-foot { display: flex; justify-content: flex-end; gap: var(--space-8); padding: var(--space-12) var(--space-16); border-top: 1px solid var(--separator); flex: none; }

  .back-btn { align-self: flex-start; display: inline-flex; align-items: center; gap: var(--space-4); padding: 0; color: var(--text2); font: var(--text-control); }
  .back-btn:hover { color: var(--paper); }
  .chat-title-row { display: flex; align-items: center; gap: var(--space-12); }
  .link-box { display: flex; flex-direction: column; gap: var(--space-12); padding: var(--space-16); border: 1px solid var(--separator); border-radius: var(--radius-panel); background: var(--surface); align-items: flex-start; }
  .field-col { display: flex; flex-direction: column; gap: var(--space-4); width: 100%; }
  .link-code { font: var(--text-code); letter-spacing: 0.08em; color: var(--paper); padding: var(--space-8) var(--space-12); border-radius: var(--radius-control); background: var(--field); user-select: text; }
  .link-img { max-width: 220px; border-radius: var(--radius-card); }
  .ok-line { color: var(--mint); }
  .end { width: 100%; justify-content: flex-end; }
</style>
