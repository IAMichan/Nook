// The centred lines about a group in the middle of a chat, as the apps show them: someone coming in or going out
// ("Ruben added David", `ChatMembership.line` on the Mac) and the group itself changing ("Anna changed the group name
// to ...", `ChatGroupChange.line`). Rust hands over names; this makes the words in the user's language.
import { locale, tr } from "./i18n.svelte";

/** You, among the names (`chats::membership::ME`). */
export const ME = "\u0001me";
/** Somebody the chat does not name (`chats::membership::SOMEONE`). */
export const SOMEONE = "\u0001someone";

export type MembershipChange = "added" | "removed" | "joined" | "left" | "gone";
export interface ChatMembership { change: MembershipChange; by?: string; people: string[] }
export type GroupChangeKind =
  | "renamed" | "described" | "photo" | "photoRemoved" | "promoted" | "demoted" | "created" | "adminsOnly" | "everyone"
  | "pinned" | "disappearing";
export interface ChatGroupChange { kind: GroupChangeKind; by?: string; text?: string; people?: string[] }

const you = () => tr("jou", "you");
const someone = () => tr("Iemand", "Someone");
/** A name as the line says it: you and an unnamed person in your language. */
const shown = (name: string) => (name === ME ? you() : name === SOMEONE || !name ? someone() : name);

/** "David", "David and Anna", "David, Anna and you" (you last, as a person says it). */
export function nameList(names: string[]): string {
  const list = [...names.filter((n) => n !== ME).map(shown), ...(names.includes(ME) ? [you()] : [])];
  if (list.length <= 1) return list[0] ?? "";
  return tr("{list} en {last}", "{list} and {last}", { list: list.slice(0, -1).join(", "), last: list[list.length - 1] });
}

/** "7 days", "24 hours", "90 minutes", in your language. */
export function duration(seconds: number): string {
  const units: [number, Intl.NumberFormatOptions["unit"]][] = [[7 * 86400, "week"], [86400, "day"], [3600, "hour"], [60, "minute"]];
  for (const [size, unit] of units) {
    if (seconds >= size && seconds % size === 0) return new Intl.NumberFormat(locale(), { style: "unit", unit, unitDisplay: "long" }).format(seconds / size);
  }
  return new Intl.NumberFormat(locale(), { style: "unit", unit: "second", unitDisplay: "long" }).format(Math.round(seconds));
}

export function membershipLine(m: ChatMembership): string {
  const people = m.people.length ? m.people : [SOMEONE];
  switch (m.change) {
    case "added": {
      const by = m.by ?? SOMEONE;
      const names = nameList(people);
      if (by === ME) return tr("Je hebt {names} toegevoegd", "You added {names}", { names });
      if (people.length === 1 && people[0] === ME) return tr("{by} heeft je toegevoegd", "{by} added you", { by: shown(by) });
      return tr("{by} heeft {names} toegevoegd", "{by} added {names}", { by: shown(by), names });
    }
    case "removed": {
      const by = m.by ?? SOMEONE;
      const names = nameList(people);
      if (by === ME) return tr("Je hebt {names} verwijderd", "You removed {names}", { names });
      if (people.length === 1 && people[0] === ME) return tr("{by} heeft je verwijderd", "{by} removed you", { by: shown(by) });
      return tr("{by} heeft {names} verwijderd", "{by} removed {names}", { by: shown(by), names });
    }
    case "joined":
      return people.map((name) => (name === ME ? tr("Je bent lid geworden", "You joined") : tr("{name} is lid geworden", "{name} joined", { name: shown(name) }))).join(" · ");
    case "left":
      return people.map((name) => (name === ME ? tr("Je hebt de groep verlaten", "You left") : tr("{name} heeft de groep verlaten", "{name} left", { name: shown(name) }))).join(" · ");
    case "gone":
      return people.map((name) => (name === ME ? tr("Je zit niet meer in de groep", "You are no longer in the group") : tr("{name} zit niet meer in de groep", "{name} is no longer in the group", { name: shown(name) }))).join(" · ");
  }
}

export function groupChangeLine(g: ChatGroupChange): string {
  const mine = g.by === ME;
  const by = shown(g.by ?? SOMEONE);
  const text = g.text ?? "";
  switch (g.kind) {
    case "renamed": return mine ? tr("Je hebt de groepsnaam gewijzigd in “{text}”", "You changed the group name to “{text}”", { text }) : tr("{by} heeft de groepsnaam gewijzigd in “{text}”", "{by} changed the group name to “{text}”", { by, text });
    case "described":
      // No text: the app does not say what it says now. An empty one: it was taken away.
      return g.text === "" ? (mine ? tr("Je hebt de groepsbeschrijving verwijderd", "You removed the group description") : tr("{by} heeft de groepsbeschrijving verwijderd", "{by} removed the group description", { by })) : (mine ? tr("Je hebt de groepsbeschrijving gewijzigd", "You changed the group description") : tr("{by} heeft de groepsbeschrijving gewijzigd", "{by} changed the group description", { by }));
    case "photo": return mine ? tr("Je hebt de groepsfoto gewijzigd", "You changed the group photo") : tr("{by} heeft de groepsfoto gewijzigd", "{by} changed the group photo", { by });
    case "photoRemoved": return mine ? tr("Je hebt de groepsfoto verwijderd", "You removed the group photo") : tr("{by} heeft de groepsfoto verwijderd", "{by} removed the group photo", { by });
    case "created":
      if (!text) return mine ? tr("Je hebt de groep gemaakt", "You created the group") : tr("{by} heeft de groep gemaakt", "{by} created the group", { by });
      return mine ? tr("Je hebt de groep “{text}” gemaakt", "You created the group “{text}”", { text }) : tr("{by} heeft de groep “{text}” gemaakt", "{by} created the group “{text}”", { by, text });
    case "adminsOnly": return mine ? tr("Je hebt ingesteld dat alleen beheerders berichten kunnen sturen", "You changed the settings so only admins can send messages") : tr("{by} heeft ingesteld dat alleen beheerders berichten kunnen sturen", "{by} changed the settings so only admins can send messages", { by });
    case "everyone": return mine ? tr("Je hebt ingesteld dat iedereen berichten kan sturen", "You changed the settings so everyone can send messages") : tr("{by} heeft ingesteld dat iedereen berichten kan sturen", "{by} changed the settings so everyone can send messages", { by });
    case "pinned": {
      if (!text) return mine ? tr("Je hebt een bericht vastgezet", "You pinned a message") : tr("{by} heeft een bericht vastgezet", "{by} pinned a message", { by });
      const start = [...text].slice(0, 60).join("");
      return mine ? tr("Je hebt “{text}” vastgezet", "You pinned “{text}”", { text: start }) : tr("{by} heeft “{text}” vastgezet", "{by} pinned “{text}”", { by, text: start });
    }
    case "disappearing": {
      const seconds = Number(text) || 0;
      if (seconds <= 0) return mine ? tr("Je hebt verdwijnende berichten uitgezet", "You turned off disappearing messages") : tr("{by} heeft verdwijnende berichten uitgezet", "{by} turned off disappearing messages", { by });
      const time = duration(seconds);
      return mine ? tr("Je hebt verdwijnende berichten ingesteld op {time}", "You set messages to disappear after {time}", { time }) : tr("{by} heeft verdwijnende berichten ingesteld op {time}", "{by} set messages to disappear after {time}", { by, time });
    }
    case "promoted":
    case "demoted": {
      const people = g.people?.length ? g.people : [SOMEONE];
      return people.map((name) => (g.kind === "promoted"
        ? name === ME ? tr("Je bent nu beheerder", "You are now an admin") : tr("{name} is nu beheerder", "{name} is now an admin", { name: shown(name) })
        : name === ME ? tr("Je bent geen beheerder meer", "You are no longer an admin") : tr("{name} is geen beheerder meer", "{name} is no longer an admin", { name: shown(name) }))).join(" · ");
    }
  }
}

/** The line a message is, when it is one about the group rather than a message; null for a message. */
export function noticeText(m: { membership?: ChatMembership | null; groupChange?: ChatGroupChange | null }): string | null {
  if (m.membership) return membershipLine(m.membership);
  if (m.groupChange) return groupChangeLine(m.groupChange);
  return null;
}
