// Every Nook feature Home can pin as an essential. A new feature is one entry here; Home and its customize sheet pick
// it up by themselves. Each entry opens the real feature (`target`) and says when this device has it (`when`).
import type { Capabilities } from "./types";
import type { Target } from "./inbox";

export type FeatureIcon =
  | "chat" | "plus" | "agents" | "workspace" | "gamepad" | "phone" | "settings" | "memory" | "link" | "brain" | "pull" | "chart"
  | "globe" | "note" | "voice";

export interface Feature {
  id: string;
  icon: FeatureIcon;
  title: [nl: string, en: string];
  hint: [nl: string, en: string];
  target: Target | { kind: "note" };
  when?: (c: Capabilities, context: { companion: boolean }) => boolean;
}

export const features: Feature[] = [
  { id: "chat", icon: "chat", title: ["Chat", "Chat"], hint: ["Je gesprekken", "Your conversations"], target: { kind: "route", route: "chat" } },
  { id: "new", icon: "plus", title: ["Nieuwe Nook", "New Nook"], hint: ["Begin een vers gesprek", "Start a fresh conversation"], target: { kind: "newNook" } },
  { id: "agents", icon: "agents", title: ["Agents", "Agents"], hint: ["Je coding-sessies", "Your coding sessions"], target: { kind: "route", route: "agents" }, when: (c) => c.localAgents },
  { id: "pulls", icon: "pull", title: ["Pull requests", "Pull requests"], hint: ["Wat op review wacht", "What waits for review"], target: { kind: "agents", select: "pulls" }, when: (c) => c.localAgents },
  { id: "terminals", icon: "workspace", title: ["Terminals", "Terminals"], hint: ["Je werkruimte", "Your workspace"], target: { kind: "workspace", page: "terminals" }, when: (c) => c.terminals },
  { id: "browser", icon: "globe", title: ["Browser", "Browser"], hint: ["De browser van Nook", "Nook's browser"], target: { kind: "workspace", page: "browser" }, when: (c) => c.terminals },
  { id: "usage", icon: "chart", title: ["Gebruik", "Usage"], hint: ["Wat je agents deden", "What your agents did"], target: { kind: "workspace", page: "usage" }, when: (c) => c.terminals },
  { id: "games", icon: "gamepad", title: ["Gamer Mode", "Gamer Mode"], hint: ["Je persoonlijke coach", "Your personal coach"], target: { kind: "route", route: "games" } },
  { id: "notetaker", icon: "note", title: ["Gesprek noteren", "Note a conversation"], hint: ["Start of stop de Notetaker", "Start or stop the Notetaker"], target: { kind: "note" }, when: (c) => c.desktop && c.microphone },
  { id: "memory", icon: "memory", title: ["Geheugen", "Memory"], hint: ["Wat Nook over je weet", "What Nook knows about you"], target: { kind: "settings", section: "memory" } },
  { id: "connections", icon: "link", title: ["Koppelingen", "Connections"], hint: ["Accounts en agenda's", "Accounts and calendars"], target: { kind: "settings", section: "accounts" } },
  { id: "brain", icon: "brain", title: ["Brein", "Brain"], hint: ["Welke AI Nook gebruikt", "Which AI Nook uses"], target: { kind: "settings", section: "brain" } },
  { id: "voice", icon: "voice", title: ["Stem en geluid", "Voice and sound"], hint: ["Praten en voorlezen", "Talking and reading aloud"], target: { kind: "settings", section: "voice" } },
  { id: "companion", icon: "phone", title: ["Companion", "Companion"], hint: ["Nook op je telefoon", "Nook on your phone"], target: { kind: "route", route: "companion" }, when: (_, x) => x.companion },
  { id: "settings", icon: "settings", title: ["Instellingen", "Settings"], hint: ["Maak Nook van jou", "Make Nook yours"], target: { kind: "route", route: "settings" } },
];

export const DEFAULT_ESSENTIALS = ["chat", "agents", "games", "memory"];

export function available(c: Capabilities | undefined, context: { companion: boolean }): Feature[] {
  return c ? features.filter((f) => !f.when || f.when(c, context)) : features.filter((f) => !f.when);
}

/// The pinned features in your order: unknown ids (a feature that left) and ones this device lacks drop out.
export function essentials(saved: string[] | null | undefined, list: Feature[]): Feature[] {
  const byId = new Map(list.map((f) => [f.id, f]));
  return [...new Set(saved ?? DEFAULT_ESSENTIALS)].flatMap((id) => byId.get(id) ?? []);
}

/// Moves `id` to `index` in `ids`, for drag and keyboard reordering.
export function moveTo(ids: string[], id: string, index: number): string[] {
  const from = ids.indexOf(id);
  if (from < 0) return ids;
  const next = ids.filter((x) => x !== id);
  next.splice(Math.max(0, Math.min(index, next.length)), 0, id);
  return next;
}
