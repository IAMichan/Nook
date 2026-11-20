// What each Nook feature puts in Home's inbox. Every provider translates its feature's own data (the same calls the
// feature's view makes) into `InboxItem`s and handles their actions; the inbox and Home know none of them by name.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { calendarBirthdays, type DayEvent } from "./birthdays";
import { api, events } from "./api";
import { agentApi, agentEvents } from "./agents";
import { chatsApi, connectorEvents, connectorsApi, health, healthLabel } from "./connectors";
import { autocomplete } from "./autocomplete";
import { appName } from "./chats-list";
import { coachingText, games } from "./games";
import { appLanguage, locale as uiLocale, tr } from "./i18n.svelte";
import { inbox, type InboxProvider } from "./inbox.svelte";
import type { InboxItem } from "./inbox";
import { pullRequests } from "./pulls.svelte";
import { serviceEvents, services } from "./services";
import { nook, relativeTime } from "./state.svelte";

type Unlisten = Promise<() => void>;
const unlisten = (...all: Unlisten[]) => () => all.forEach((u) => u.then((f) => f()));

const HOUR = 3_600_000;
const locale = () => uiLocale();
const clock = (d: Date) => d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });

/// "today at 10:00", "tomorrow at 10:00", or "Tue 4 Nov, 10:00".
export function when(iso: string, now = new Date()): string {
  const d = new Date(iso);
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(d) - day(now)) / 86_400_000);
  if (days === 0) return tr("vandaag om {time}", "today at {time}", { time: clock(d) });
  if (days === 1) return tr("morgen om {time}", "tomorrow at {time}", { time: clock(d) });
  return d.toLocaleString(locale(), { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

/// Conversations: one waiting for your answer needs you; one Nook finished while you were away is something you missed.
const chats: InboxProvider = {
  id: "chats",
  async load() {
    return nook.nooks
      .filter((n) => !n.archived && (n.status === "waiting" || n.status === "unread"))
      .map((n): InboxItem => ({
        id: `nook:${n.id}:${n.status}:${n.updated}`,
        provider: "chats",
        ref: n.id,
        source: "chats",
        type: n.status === "waiting" ? "action_required" : "missed",
        cared: n.status === "waiting",
        title: n.title || tr("Een gesprek", "A conversation"),
        detail: n.status === "waiting" ? tr("Nook wacht op je antwoord", "Nook is waiting for your answer") : tr("Nook antwoordde terwijl je weg was", "Nook answered while you were away"),
        at: n.updated,
        actions: [{ id: "open", label: tr("Openen", "Open") }],
      }));
  },
  act: (item) => (item.ref ? { kind: "nook", id: item.ref } : undefined),
  watch: (changed) => unlisten(events.onNookUpdated(() => setTimeout(changed, 300))),
};

/// Open items Nook keeps for you that are due within a day, or overdue: you asked to be reminded.
const tasks: InboxProvider = {
  id: "tasks",
  async load() {
    const now = Date.now();
    return (await api.openLoops())
      .filter((l) => l.due && Date.parse(l.due) - now < 24 * HOUR)
      .map((l): InboxItem => {
        const due = Date.parse(l.due!);
        const late = due < now;
        return {
          id: `loop:${l.id}:${l.due}`,
          provider: "tasks",
          ref: l.id,
          source: "tasks",
          type: "reminder",
          cared: true,
          weight: late || due - now < HOUR ? 2 : 1,
          title: l.title,
          detail: late ? tr("Was {when}", "Was due {when}", { when: when(l.due!) }) : tr("Gepland {when}", "Due {when}", { when: when(l.due!) }),
          at: l.due!,
          actions: [{ id: "done", label: tr("Afvinken", "Mark done") }],
        };
      });
  },
  async act(item, action) {
    if (action === "done" && item.ref) await api.completeLoop(item.ref);
  },
  watch: (changed) => unlisten(events.onNookUpdated(changed)),
};

interface UpcomingEvent { title: string; start: string; end: string; allDay: boolean; location: string; calendar: string }

/// The next few events in your linked calendars (from their cache, so this never waits on the network).
const calendar: InboxProvider = {
  id: "calendar",
  async load() {
    const now = Date.now();
    const list = await invoke<UpcomingEvent[]>("agenda_upcoming", { hours: 36 });
    return list
      .filter((e) => !e.allDay)
      .slice(0, 3)
      .map((e): InboxItem => {
        const soon = Date.parse(e.start) - now;
        const today = new Date(e.start).toDateString() === new Date(now).toDateString();
        return {
          id: `event:${e.calendar}:${e.title}:${e.start}`,
          provider: "calendar",
          source: "calendar",
          type: "reminder",
          weight: soon < HOUR ? 2 : today ? 1 : 0,
          title: e.title,
          detail: [when(e.start), e.location].filter(Boolean).join(" · "),
          at: e.start,
          actions: [{ id: "prepare", label: tr("Voorbereiden", "Prepare") }],
        };
      });
  },
  act: (item) => ({
    kind: "newNook",
    ask: tr("Help me me voor te bereiden op \"{title}\" ({detail}).", "Help me prepare for \"{title}\" ({detail}).", { title: item.title, detail: item.detail ?? "" }),
  }),
  watch: (changed) => unlisten(connectorEvents.onChanged(changed)),
};

/// Coding agents waiting on an approval or an answer.
const agents: InboxProvider = {
  id: "agents",
  async load() {
    if (!nook.info?.capabilities.localAgents) return [];
    const o = await agentApi.overview();
    const approvals = o.approvals.map((a): InboxItem => ({
      id: `approval:${a.id}`,
      provider: "agents",
      source: "agents",
      type: "action_required",
      cared: true,
      title: tr("{agent} vraagt toestemming", "{agent} needs your approval", { agent: a.agentName }),
      detail: [a.title, a.project].filter(Boolean).join(" · "),
      at: a.created,
      actions: [{ id: a.sessionKey, label: tr("Bekijken", "Review") }],
    }));
    const questions = o.questions.map((q): InboxItem => ({
      id: `question:${q.id}`,
      provider: "agents",
      source: "agents",
      type: "action_required",
      cared: true,
      title: tr("{agent} heeft een vraag", "{agent} has a question", { agent: q.agentName }),
      detail: [q.items[0]?.question, q.project].filter(Boolean).join(" · "),
      at: new Date().toISOString(),
      actions: [{ id: q.sessionKey, label: tr("Beantwoorden", "Answer") }],
    }));
    // A session that failed is something you missed (the Mac's Today: agents waiting or failed).
    const failed = o.sessions.filter((x) => x.status === "failed").slice(0, 3).map((x): InboxItem => ({
      id: `failed:${x.id}:${x.summary}`,
      provider: "agents",
      source: "agents",
      type: "missed",
      title: tr("{name} is mislukt", "{name} failed", { name: x.name || x.project }),
      detail: [x.summary, x.project].filter(Boolean).join(" · "),
      at: new Date().toISOString(),
      actions: [{ id: x.id, label: tr("Bekijken", "Review") }],
    }));
    return [...approvals, ...questions, ...failed];
  },
  act: (_, action) => ({ kind: "agents", select: action }),
  watch: (changed) => unlisten(agentEvents.onChanged(changed), agentEvents.onApproval(changed), agentEvents.onQuestion(changed)),
};

/// WhatsApp chats with messages you have not read.
const messages: InboxProvider = {
  id: "messages",
  async load() {
    const chats = await connectorsApi.whatsappChatList();
    return chats
      .filter((c) => c.unread > 0)
      .sort((a, b) => Date.parse(b.lastActivity) - Date.parse(a.lastActivity))
      .slice(0, 3)
      .map((c): InboxItem => {
        const last = [...(c.messages ?? [])].reverse().find((m) => !m.fromMe);
        return {
          id: `whatsapp:${c.id}:${c.lastActivity}`,
          provider: "messages",
          ref: c.id,
          source: "messages",
          type: "missed",
          title: c.unread > 1 ? tr("{name} · {n} berichten", "{name} · {n} messages", { name: c.name, n: c.unread }) : c.name,
          detail: last?.text || tr("Nieuw bericht op WhatsApp", "New message on WhatsApp"),
          at: c.lastActivity,
          actions: [{ id: "reply", label: tr("Antwoord voorstellen", "Draft a reply") }, { id: "read", label: tr("Gelezen", "Mark read") }],
        };
      });
  },
  async act(item, action) {
    const chat = item.ref;
    if (!chat) return;
    if (action === "read") return void (await connectorsApi.whatsappMarkRead(chat));
    return { kind: "nook", id: await connectorsApi.whatsappAskNook(chat) };
  },
  watch: (changed) => unlisten(connectorEvents.onWhatsApp(changed), connectorEvents.onChanged(changed)),
};

/// The chats you owe a reply in, every chat app at once (the Mac's `owedChatAttention`): the first few, questions first.
const owed: InboxProvider = {
  id: "owed",
  async load() {
    return (await chatsApi.owed(3)).map((t): InboxItem => ({
      id: `owed:${t.chat}:${t.date ?? ""}`,
      provider: "owed",
      ref: t.chat,
      source: "messages",
      type: "action_required",
      cared: true,
      title: tr("{name} wacht op je antwoord", "{name} is waiting for your reply", { name: t.name }),
      detail: [appName(t.app), t.date ? relativeTime(t.date) : ""].filter(Boolean).join(" · "),
      at: t.date ?? new Date().toISOString(),
      actions: [{ id: "reply", label: tr("Antwoorden", "Reply") }],
    }));
  },
  act: (item) => (item.ref ? { kind: "chat", key: item.ref } : undefined),
  watch: (changed) => unlisten(connectorEvents.onChats(changed)),
};

/// Birthdays today (the Mac's `birthdayAttention`): the people you gave a birthday in a chat's info, with Reply in their
/// chat, and all-day birthday events in your calendars.
const birthdays: InboxProvider = {
  id: "birthdays",
  async load() {
    const today = new Date();
    const people = await invoke<{ key: string; name: string; app: string }[]>("birthdays_today").catch(() => []);
    const events = await invoke<DayEvent[]>("agenda_upcoming", { hours: 24 }).catch(() => []);
    const named = new Set(people.map((p) => p.name.toLowerCase()));
    const fromChats = people.map((p): InboxItem => ({
      id: `birthday:${p.key}:${today.toDateString()}`,
      provider: "birthdays",
      ref: p.key,
      source: "messages",
      type: "reminder",
      weight: 1,
      title: tr("{name} is vandaag jarig", "It's {name}'s birthday today", { name: p.name }),
      detail: appName(p.app),
      at: today.toISOString(),
      actions: [{ id: "reply", label: tr("Antwoorden", "Reply") }],
    }));
    const fromCalendar = calendarBirthdays(events, today)
      .filter((b) => !named.has(b.name.toLowerCase()))
      .map((b): InboxItem => ({
        id: `birthday:calendar:${b.title}:${today.toDateString()}`,
        provider: "birthdays",
        source: "calendar",
        type: "reminder",
        weight: 1,
        title: tr("{name} is vandaag jarig", "It's {name}'s birthday today", { name: b.name }),
        detail: b.title,
        at: today.toISOString(),
        actions: [{ id: "write", label: tr("Felicitatie schrijven", "Write a congratulation") }],
      }));
    return [...fromChats, ...fromCalendar];
  },
  act: (item) => item.ref
    ? { kind: "chat", key: item.ref }
    : { kind: "newNook", ask: tr("Help me een korte felicitatie te schrijven voor: {detail}", "Help me write a short congratulation for: {detail}", { detail: item.detail ?? item.title }) },
  watch: (changed) => unlisten(connectorEvents.onChanged(changed), listen("person-notes", changed)),
};

/// A linked service that stopped working or needs you to sign in again (the Mac's `connectors.needingAttention`), at most
/// two, opening Settings › Connections.
const connectorFailures: InboxProvider = {
  id: "connectors",
  async load() {
    const o = await connectorsApi.overview();
    return o.connectors
      .filter((c) => { const h = health(c); return h === "broken" || h === "needsYou"; })
      .slice(0, 2)
      .map((c): InboxItem => ({
        id: `connector:${c.id}:${c.status.headline}`,
        provider: "connectors",
        ref: c.id,
        source: "system",
        type: "action_required",
        title: `${c.title}: ${c.status.headline || healthLabel[health(c)]}`,
        detail: c.status.detail || c.status.items[0]?.title || "",
        at: c.status.updated ?? new Date().toISOString(),
        actions: [{ id: "view", label: tr("Bekijken", "View") }],
      }));
  },
  act: () => ({ kind: "settings", section: "connections" }),
  watch: (changed) => unlisten(connectorEvents.onChanged(changed)),
};

/// What autocomplete saved you today (the Mac's `autocompleteTodayItem`): a calm line, only when it completed something.
const typing: InboxProvider = {
  id: "typing",
  async load() {
    if (!nook.info?.capabilities.autocomplete) return [];
    const view = await autocomplete.view();
    const day = view.stats.today;
    if (!day.takes) return [];
    const minutes = Math.max(1, Math.round(day.words / 40));
    return [{
      id: `typing:${new Date().toDateString()}:${day.takes}`,
      provider: "typing",
      source: "system",
      type: "update",
      title: tr("{n}× aangevuld vandaag", "{n}× completed today", { n: day.takes }),
      detail: tr("{words} woorden, zo'n {minutes} min typen bespaard", "{words} words, about {minutes} min of typing saved", { words: day.words, minutes }),
      at: new Date().toISOString(),
      actions: [{ id: "view", label: tr("Bekijken", "View") }],
    }];
  },
  act: () => ({ kind: "settings", section: "autocompleteStats" }),
};

/// Pull requests waiting for your review, and your own whose checks fail, from the list Agents › Pull requests keeps.
const code: InboxProvider = {
  id: "code",
  async load() {
    if (!nook.info?.capabilities.localAgents) return [];
    return pullRequests.accounts.flatMap((a) => [
      ...a.reviews.filter((p) => p.state === "open" && !p.draft).map((p): InboxItem => ({
        id: `review:${p.repo}#${p.number}`,
        provider: "code",
        source: "code",
        type: "action_required",
        title: p.title,
        detail: tr("{author} vraagt je review · {repo}#{number}", "{author} asked for your review · {repo}#{number}", { author: p.author, repo: p.repo, number: p.number }),
        at: p.updated ?? new Date().toISOString(),
        actions: [{ id: "open", label: tr("Bekijken", "Review") }],
      })),
      ...a.mine.filter((p) => p.state === "open" && p.ci === "failing").map((p): InboxItem => ({
        id: `failing:${p.repo}#${p.number}:${p.updated}`,
        provider: "code",
        source: "code",
        type: "update",
        weight: 1,
        title: p.title,
        detail: tr("Checks mislukt · {repo}#{number}", "Checks failed · {repo}#{number}", { repo: p.repo, number: p.number }),
        at: p.updated ?? new Date().toISOString(),
        actions: [{ id: "open", label: tr("Bekijken", "View") }],
      })),
    ]);
  },
  act: () => ({ kind: "agents", select: "pulls" }),
};

/// Nook's Think Along offers, conversation notes and the weekly recap (what the bar's Today shows).
const today: InboxProvider = {
  id: "today",
  async load() {
    if (!nook.info?.capabilities.desktop) return [];
    const now = new Date().toISOString();
    return (await services.today())
      .filter((t) => t.kind !== "recording")
      .map((t): InboxItem => ({
        id: `today:${t.kind}:${t.id}`,
        provider: "today",
        ref: `${t.kind}:${t.id}`,
        source: t.kind === "nudge" ? "ai" : t.kind === "note" ? "notes" : "system",
        type: t.kind === "nudge" ? "insight" : "update",
        weight: t.kind === "note" ? 1 : 0,
        title: t.title,
        detail: t.subtitle,
        at: now,
        actions: [{ id: "open", label: tr("Bekijken", "View") }],
      }));
  },
  async act(item) {
    const [kind, ...rest] = (item.ref ?? "").split(":");
    const id = rest.join(":");
    if (kind === "nudge") await services.answerNudge(id, "open");
    else if (kind === "recap") return { kind: "workspace", page: "usage" };
    else if (kind === "note") {
      const markdown = await services.noteMarkdown(id);
      if (markdown) return { kind: "markdown", title: item.title, markdown };
    }
  },
  watch: (changed) => unlisten(serviceEvents.onNudge(changed), serviceEvents.onNoteLive(changed)),
};

/// The Valorant Coach's newest warning from your latest match.
const gamerMode: InboxProvider = {
  id: "gamer_mode",
  async load() {
    const view = await games.view();
    const match = view.current;
    const insight = (view.analysis?.insights ?? []).filter((i) => i.severity !== "info").sort((a, b) => b.round - a.round)[0];
    if (!match || !insight) return [];
    const { title, body } = coachingText(insight, appLanguage());
    return [{
      id: `coach:${match.id}:${insight.id}`,
      provider: "gamer_mode",
      source: "gamer_mode",
      type: "insight",
      title,
      detail: body,
      at: match.ended ?? view.lastLook ?? match.started,
      actions: [{ id: "open", label: tr("Analyse bekijken", "View analysis") }],
    }];
  },
  act: () => ({ kind: "route", route: "games" }),
  watch: (changed) => unlisten(games.onUpdated(changed)),
};

let registered = false;

export function registerInboxSources() {
  if (registered) return;
  registered = true;
  for (const p of [agents, chats, owed, birthdays, tasks, calendar, messages, code, connectorFailures, today, typing, gamerMode]) inbox.register(p);
}
