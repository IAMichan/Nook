// Gamer Mode: the list of games and the Valorant Coach. Same shapes as the Rust structs (serde, camelCase); the coach
// in `nook_core::games` decides what to say, this file only words it (Dutch and English, like `tr`).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

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

type Lang = "nl" | "en";
const t = (lang: Lang, nl: string, en: string) => (lang === "en" ? en : nl);

/// Seconds into the round as the game shows time: 6 → "0:06".
export function clock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

export function listRounds(rounds: number[], lang: Lang): string {
  if (rounds.length <= 1) return rounds.join("");
  return `${rounds.slice(0, -1).join(", ")} ${t(lang, "en", "and")} ${rounds[rounds.length - 1]}`;
}

/// What to do about a setup of this kind, before entering `location`.
function advice(kind: AbilityKind | null, location: string, time: number | null, lang: Lang): string {
  switch (kind) {
    case "trap": return t(lang, `Check deze plek voordat je ${location} in loopt.`, `Check this location before entering ${location}.`);
    case "flash": return time !== null
      ? t(lang, `Verwacht hem vroeg in de ronde, rond ${clock(time)}.`, `Expect it early in the round, around ${clock(time)}.`)
      : t(lang, "Verwacht hem en kijk weg of wacht hem af.", "Expect it and turn away or wait it out.");
    case "recon": return t(lang, `Reken erop dat je bij ${location} gezien wordt; schiet hem kapot of blijf uit zicht.`, `Expect to be revealed at ${location}; shoot it or stay out of its line.`);
    default: return t(lang, `Houd er rekening mee bij ${location}.`, `Plan around it at ${location}.`);
  }
}

export interface Coaching { title: string; body: string }

export function habitText(habit: Habit, lang: Lang): Coaching {
  if (habit.type === "repeatTrigger") {
    return {
      title: t(lang, "Dezelfde fout", "Same mistake again"),
      body: t(lang,
        `Je liep ${habit.count} keer in dezelfde ${habit.abilityName} van ${habit.agentName} bij ${habit.location}. Check voortaan utility die al eerder gezien is voordat je een site in gaat.`,
        `You have triggered the same ${habit.agentName} ${habit.abilityName} at ${habit.location} ${habit.count} times. You should start checking previously identified utility before entering sites.`),
    };
  }
  return {
    title: t(lang, "Steeds dezelfde plek", "Same spot again"),
    body: t(lang,
      `Je ging in ${habit.count} rondes dood bij ${habit.location} (rondes ${listRounds(habit.rounds, lang)}). Probeer een andere hoek of wacht op utility.`,
      `You died at ${habit.location} in ${habit.count} rounds (rounds ${listRounds(habit.rounds, lang)}). Try a different angle or wait for utility.`),
  };
}

/// One piece of advice in words.
export function coachingText(insight: Insight, lang: Lang): Coaching {
  switch (insight.type) {
    case "patternStrong": {
      const seen = insight.hits >= 2
        ? t(lang, `Je liep er al ${insight.hits} keer in.`, `You've triggered it ${insight.hits} times.`)
        : insight.streak >= 3
          ? t(lang, `Je zag hem ${insight.streak} rondes op rij.`, `You've seen it ${insight.streak} rounds in a row.`)
          : t(lang, `Al ${insight.occurrences} keer gebruikt.`, `Used ${insight.occurrences} times.`);
      return {
        title: t(lang, `Patroon van ${insight.agentName}`, `${insight.agentName} pattern detected`),
        body: `${t(lang, `${insight.agentName} gebruikt steeds ${insight.abilityName} bij ${insight.location}.`, `${insight.agentName} keeps reusing ${insight.abilityName} at ${insight.location}.`)} ${seen} ${advice(insight.kind, insight.location, insight.typicalTime, lang)}`,
      };
    }
    case "patternForming":
      return {
        title: t(lang, `Mogelijk patroon van ${insight.agentName}`, `Possible ${insight.agentName} pattern`),
        body: t(lang,
          `${insight.abilityName} bij ${insight.location} in rondes ${listRounds(insight.rounds, lang)}. Nook let op of het terugkomt.`,
          `${insight.abilityName} at ${insight.location} in rounds ${listRounds(insight.rounds, lang)}. Nook is watching whether it repeats.`),
      };
    case "patternChanged":
      return {
        title: t(lang, `${insight.agentName} veranderde de setup`, `${insight.agentName} changed the usual setup`),
        body: [
          t(lang,
            `De gewone ${insight.abilityName} bij ${insight.location} (${insight.occurrences} keer eerder) was er in ronde ${insight.round} niet.`,
            `The usual ${insight.abilityName} at ${insight.location} (used ${insight.occurrences} times before) wasn't detected in round ${insight.round}.`),
          insight.movedTo ? t(lang, `Hij lag nu bij ${insight.movedTo}.`, `It showed up at ${insight.movedTo} instead.`) : "",
          t(lang, "Reken niet blind op de oude setup.", "Be careful relying on the old setup."),
        ].filter(Boolean).join(" "),
      };
    case "goodAdaptation":
      return {
        title: t(lang, "Goed aangepast", "Good adaptation"),
        body: t(lang,
          `Je ontweek de gewone ${insight.abilityName} van ${insight.agentName} bij ${insight.location}. Die is nu ${insight.occurrences} keer gebruikt.`,
          `You avoided ${insight.agentName}'s usual ${insight.abilityName} at ${insight.location}. It has now been used ${insight.occurrences} times.`),
      };
    case "habit":
      return habitText(insight.habit, lang);
  }
}

/// General knowledge for an enemy agent, before Nook has seen anything of theirs.
export function generalText(tip: GeneralTip, lang: Lang): string {
  switch (tip.kind) {
    case "trap": return t(lang, `${tip.agentName} zet ${tip.abilityName} vaak bij ingangen en chokes.`, `${tip.agentName} commonly places ${tip.abilityName} at choke points and entrances.`);
    case "flash": return t(lang, `${tip.agentName} opent rondes vaak met ${tip.abilityName}.`, `${tip.agentName} often opens rounds with ${tip.abilityName}.`);
    default: return t(lang, `${tip.agentName} zoekt informatie met ${tip.abilityName}.`, `${tip.agentName} gathers information with ${tip.abilityName}.`);
  }
}

export function confidenceLabel(c: Confidence, lang: Lang): string {
  return c === "high" ? t(lang, "Hoog", "High") : c === "medium" ? t(lang, "Gemiddeld", "Medium") : t(lang, "Laag", "Low");
}

export function statusLabel(s: PatternStatus, occurrences: number, lang: Lang): string {
  if (s.state === "changed") return t(lang, `Veranderd in ronde ${s.round}`, `Changed in round ${s.round}`);
  if (s.state === "stale") return t(lang, `Niet meer gezien sinds ronde ${s.since}`, `Not seen since round ${s.since}`);
  return occurrences >= 3 ? t(lang, "Sterk patroon", "Strong pattern") : occurrences === 2 ? t(lang, "Mogelijk patroon", "Possible pattern") : t(lang, "Eén keer gezien", "Seen once");
}

/// Advice worth a notice: warnings and good news, not "maybe".
export function newCoaching(before: Set<string>, insights: Insight[]): Insight[] {
  return insights.filter((i) => i.severity !== "info" && !before.has(i.id));
}
