// Gamer Mode: the list of games and the Valorant Coach. Same shapes as the Rust structs (serde, camelCase); the coach
// in `nook_core::games` decides what to say, this file only words it, in the interface language (like `tr`).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { fill, translate, type AppLanguage, type Vars } from "./i18n.svelte";

export interface GameInfo {
  id: string;
  title: string;
  processes: string[];
}

export type AbilityKind = "trap" | "recon" | "flash" | "smoke" | "damage" | "debuff" | "wall" | "movement" | "heal" | "ultimate";
export type Side = "enemy" | "me" | "ally";
export type EventKind = "utility" | "death" | "kill";
export type Effect = "seen" | "hit" | "avoided" | "destroyed";

export interface Ability { id: string; name: string; slot: string; kind: AbilityKind }
export interface Agent { id: string; name: string; abilities: Ability[] }
export interface ValorantCatalog { agents: Agent[]; maps: string[] }

export interface MatchEvent {
  id: string;
  round: number;
  kind: EventKind;
  side: Side;
  agent: string | null;
  ability: string | null;
  location: string;
  roundTime: number | null;
  effect: Effect;
  confidence: number;
  source: "manual" | "screen";
  at: string;
}

export interface Round { number: number; started: string; closed: boolean; events: MatchEvent[] }

export interface Match {
  id: string;
  started: string;
  ended: string | null;
  map: string | null;
  myAgent: string | null;
  rounds: Round[];
}

export type Confidence = "low" | "medium" | "high";
export type PatternStatus =
  | { state: "active" }
  | { state: "changed"; round: number; movedTo: string | null }
  | { state: "stale"; since: number };

export interface Pattern {
  key: string;
  agent: string;
  agentName: string;
  ability: string;
  abilityName: string;
  kind: AbilityKind | null;
  location: string;
  rounds: number[];
  occurrences: number;
  streak: number;
  typicalTime: number | null;
  hits: number;
  avoided: number;
  confidence: Confidence;
  status: PatternStatus;
}

interface SetupFacts { agentName: string; abilityName: string; kind: AbilityKind | null; location: string }

export type Habit =
  | ({ type: "repeatTrigger"; key: string; count: number; rounds: number[] } & SetupFacts)
  | { type: "repeatDeath"; location: string; count: number; rounds: number[] };

export type InsightBody =
  | ({ type: "patternForming"; occurrences: number; rounds: number[] } & SetupFacts)
  | ({ type: "patternStrong"; occurrences: number; streak: number; hits: number; typicalTime: number | null } & SetupFacts)
  | ({ type: "patternChanged"; occurrences: number; movedTo: string | null } & SetupFacts)
  | ({ type: "goodAdaptation"; occurrences: number } & SetupFacts)
  | { type: "habit"; habit: Habit };

export type Severity = "warning" | "info" | "success";
export type Insight = { id: string; round: number; severity: Severity } & InsightBody;

export interface GeneralTip { agentName: string; abilityName: string; kind: AbilityKind }

export interface Analysis { patterns: Pattern[]; habits: Habit[]; insights: Insight[]; general: GeneralTip[] }

export interface GamerPrefs { enabled: boolean; intervalSecs: number; notify: boolean }

export interface MatchSummary { id: string; started: string; map: string | null; myAgent: string | null; rounds: number; patterns: number }

export interface CoachView {
  prefs: GamerPrefs;
  inGame: boolean;
  looking: boolean;
  lastLook: string | null;
  lastError: string | null;
  current: Match | null;
  analysis: Analysis | null;
  history: MatchSummary[];
}

export interface EventInput {
  round?: number;
  kind: EventKind;
  side: Side;
  agent?: string;
  ability?: string;
  location: string;
  roundTime?: number;
  effect: Effect;
}

export const games = {
  list: () => invoke<GameInfo[]>("games_list"),
  catalog: () => invoke<ValorantCatalog>("valorant_catalog"),
  view: () => invoke<CoachView>("valorant_view"),
  savePrefs: (prefs: GamerPrefs) => invoke<CoachView>("valorant_save_prefs", { prefs }),
  startMatch: (map?: string | null, agent?: string | null) => invoke<CoachView>("valorant_start_match", { map, agent }),
  endMatch: () => invoke<CoachView>("valorant_end_match"),
  setMatch: (map: string | null, agent: string | null) => invoke<CoachView>("valorant_set_match", { map, agent }),
  nextRound: () => invoke<CoachView>("valorant_next_round"),
  record: (input: EventInput) => invoke<CoachView>("valorant_record", { input }),
  remove: (id: string) => invoke<CoachView>("valorant_remove", { id }),
  look: () => invoke<number>("valorant_look"),
  onUpdated: (cb: (view: CoachView) => void): Promise<UnlistenFn> => listen<CoachView>("valorant-updated", (e) => cb(e.payload)),
};

/// The language to word coaching in: any interface language. German, French, and Spanish come from the catalog
/// (`i18n/lib.ts`), keyed by the English text, the same way `tr` does it.
type Lang = AppLanguage;
const t = (lang: Lang, nl: string, en: string, vars?: Vars) => fill(translate(lang, nl, en), vars);

/// Seconds into the round as the game shows time: 6 → "0:06".
export function clock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

export function listRounds(rounds: number[], lang: Lang): string {
  if (rounds.length <= 1) return rounds.join("");
  return t(lang, "{list} en {last}", "{list} and {last}", { list: rounds.slice(0, -1).join(", "), last: rounds[rounds.length - 1] });
}

/// What to do about a setup of this kind, before entering `location`.
function advice(kind: AbilityKind | null, location: string, time: number | null, lang: Lang): string {
  switch (kind) {
    case "trap": return t(lang, "Check deze plek voordat je {location} in loopt.", "Check this location before entering {location}.", { location });
    case "flash": return time !== null
      ? t(lang, "Verwacht hem vroeg in de ronde, rond {time}.", "Expect it early in the round, around {time}.", { time: clock(time) })
      : t(lang, "Verwacht hem en kijk weg of wacht hem af.", "Expect it and turn away or wait it out.");
    case "recon": return t(lang, "Reken erop dat je bij {location} gezien wordt; schiet hem kapot of blijf uit zicht.", "Expect to be revealed at {location}; shoot it or stay out of its line.", { location });
    default: return t(lang, "Houd er rekening mee bij {location}.", "Plan around it at {location}.", { location });
  }
}

export interface Coaching { title: string; body: string }

export function habitText(habit: Habit, lang: Lang): Coaching {
  if (habit.type === "repeatTrigger") {
    const vars = { count: habit.count, agent: habit.agentName, ability: habit.abilityName, location: habit.location };
    return {
      title: t(lang, "Dezelfde fout", "Same mistake again"),
      body: t(lang,
        "Je liep {count} keer in dezelfde {ability} van {agent} bij {location}. Check voortaan utility die al eerder gezien is voordat je een site in gaat.",
        "You have triggered the same {agent} {ability} at {location} {count} times. You should start checking previously identified utility before entering sites.",
        vars),
    };
  }
  return {
    title: t(lang, "Steeds dezelfde plek", "Same spot again"),
    body: t(lang,
      "Je ging in {count} rondes dood bij {location} (rondes {rounds}). Probeer een andere hoek of wacht op utility.",
      "You died at {location} in {count} rounds (rounds {rounds}). Try a different angle or wait for utility.",
      { count: habit.count, location: habit.location, rounds: listRounds(habit.rounds, lang) }),
  };
}

/// One piece of advice in words.
export function coachingText(insight: Insight, lang: Lang): Coaching {
  if (insight.type === "habit") return habitText(insight.habit, lang);
  const vars = { agent: insight.agentName, ability: insight.abilityName, location: insight.location, occurrences: insight.occurrences };
  switch (insight.type) {
    case "patternStrong": {
      const seen = insight.hits >= 2
        ? t(lang, "Je liep er al {n} keer in.", "You've triggered it {n} times.", { n: insight.hits })
        : insight.streak >= 3
          ? t(lang, "Je zag hem {n} rondes op rij.", "You've seen it {n} rounds in a row.", { n: insight.streak })
          : t(lang, "Al {n} keer gebruikt.", "Used {n} times.", { n: insight.occurrences });
      return {
        title: t(lang, "Patroon van {agent}", "{agent} pattern detected", vars),
        body: [
          t(lang, "{agent} gebruikt steeds {ability} bij {location}.", "{agent} keeps reusing {ability} at {location}.", vars),
          seen,
          advice(insight.kind, insight.location, insight.typicalTime, lang),
        ].join(" "),
      };
    }
    case "patternForming":
      return {
        title: t(lang, "Mogelijk patroon van {agent}", "Possible {agent} pattern", vars),
        body: t(lang,
          "{ability} bij {location} in rondes {rounds}. Nook let op of het terugkomt.",
          "{ability} at {location} in rounds {rounds}. Nook is watching whether it repeats.",
          { ...vars, rounds: listRounds(insight.rounds, lang) }),
      };
    case "patternChanged":
      return {
        title: t(lang, "{agent} veranderde de setup", "{agent} changed the usual setup", vars),
        body: [
          t(lang,
            "De gewone {ability} bij {location} ({occurrences} keer eerder) was er in ronde {round} niet.",
            "The usual {ability} at {location} (used {occurrences} times before) wasn't detected in round {round}.",
            { ...vars, round: insight.round }),
          insight.movedTo ? t(lang, "Hij lag nu bij {place}.", "It showed up at {place} instead.", { place: insight.movedTo }) : "",
          t(lang, "Reken niet blind op de oude setup.", "Be careful relying on the old setup."),
        ].filter(Boolean).join(" "),
      };
    case "goodAdaptation":
      return {
        title: t(lang, "Goed aangepast", "Good adaptation"),
        body: t(lang,
          "Je ontweek de gewone {ability} van {agent} bij {location}. Die is nu {occurrences} keer gebruikt.",
          "You avoided {agent}'s usual {ability} at {location}. It has now been used {occurrences} times.",
          vars),
      };
  }
}

/// General knowledge for an enemy agent, before Nook has seen anything of theirs.
export function generalText(tip: GeneralTip, lang: Lang): string {
  const vars = { agent: tip.agentName, ability: tip.abilityName };
  switch (tip.kind) {
    case "trap": return t(lang, "{agent} zet {ability} vaak bij ingangen en chokes.", "{agent} commonly places {ability} at choke points and entrances.", vars);
    case "flash": return t(lang, "{agent} opent rondes vaak met {ability}.", "{agent} often opens rounds with {ability}.", vars);
    default: return t(lang, "{agent} zoekt informatie met {ability}.", "{agent} gathers information with {ability}.", vars);
  }
}

export function confidenceLabel(c: Confidence, lang: Lang): string {
  return c === "high" ? t(lang, "Hoog", "High") : c === "medium" ? t(lang, "Gemiddeld", "Medium") : t(lang, "Laag", "Low");
}

export function statusLabel(s: PatternStatus, occurrences: number, lang: Lang): string {
  if (s.state === "changed") return t(lang, "Veranderd in ronde {round}", "Changed in round {round}", { round: s.round });
  if (s.state === "stale") return t(lang, "Niet meer gezien sinds ronde {round}", "Not seen since round {round}", { round: s.since });
  return occurrences >= 3 ? t(lang, "Sterk patroon", "Strong pattern") : occurrences === 2 ? t(lang, "Mogelijk patroon", "Possible pattern") : t(lang, "Eén keer gezien", "Seen once");
}

/// Advice worth a notice: warnings and good news, not "maybe".
export function newCoaching(before: Set<string>, insights: Insight[]): Insight[] {
  return insights.filter((i) => i.severity !== "info" && !before.has(i.id));
}
