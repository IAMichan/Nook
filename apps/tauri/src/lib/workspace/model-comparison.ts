// Sending one prompt to several models (`ModelComparison` on the Mac): the new-session composer starts one session per
// chosen model, each in its own worktree. Pure decisions about the selection, the configurations and what a partly
// failed send leaves behind; `NewSession.svelte` runs them. No interface code, so tests use it on its own.
import type { NewRunConfig, PermissionPolicy, RunProvider } from "./api";

/** One model to send the prompt to: the agent, the account it runs under and the model (empty: the agent's default). */
export interface ComparisonTarget {
  provider: RunProvider;
  profileId: string;
  model: string;
}

/** At most this many sessions start from one prompt: each one is a worktree and an agent running at once. */
export const MAX_MODELS = 4;

const same = (a: ComparisonTarget, b: ComparisonTarget) => a.provider === b.provider && a.profileId === b.profileId && a.model === b.model;

/** Adds or removes a model next to the one the composer has chosen. The chosen model always stays; the list keeps the
 * order you picked in and never grows past `MAX_MODELS` together with it. */
export function toggling(target: ComparisonTarget, extras: ComparisonTarget[], primary: ComparisonTarget): ComparisonTarget[] {
  if (same(target, primary)) return extras.filter((e) => !same(e, primary));
  if (extras.some((e) => same(e, target))) return extras.filter((e) => !same(e, target));
  const kept = extras.filter((e) => !same(e, primary));
  return kept.length + 1 >= MAX_MODELS ? kept : [...kept, target];
}

/** Every model the prompt goes to: the chosen one first, then the others without doubles, capped at `MAX_MODELS`. */
export function targets(primary: ComparisonTarget, extras: ComparisonTarget[]): ComparisonTarget[] {
  const out: ComparisonTarget[] = [];
  for (const t of [primary, ...extras]) if (!out.some((o) => same(o, t))) out.push(t);
  return out.slice(0, MAX_MODELS);
}

/** One configuration per target, from the composer's own: each in a new worktree, titled after the task and the model
 * so the rows tell them apart. An access level the agent does not support falls back to one it does; the effort only
 * carries over within the same agent. `policies` names what each agent supports. */
export function configs(
  base: NewRunConfig,
  list: ComparisonTarget[],
  modelName: (t: ComparisonTarget) => string,
  policies: (p: RunProvider) => PermissionPolicy[],
  titleFrom: (task: string) => string,
): NewRunConfig[] {
  const title = base.title.trim() || titleFrom(base.task);
  return list.map((t) => {
    const supported = policies(t.provider);
    let permission = base.permission;
    if (supported.length && !supported.includes(permission)) {
      permission = supported.includes("acceptEdits") ? "acceptEdits" : supported[0];
    }
    return {
      ...base,
      provider: t.provider,
      profileId: t.profileId,
      model: t.model,
      isolation: "worktree",
      branchName: "",
      title: `${title} · ${modelName(t)}`,
      effort: t.provider === base.provider ? base.effort : null,
      permission,
    };
  });
}

/** How a comparison went: which targets started (with their session) and which failed (with why). */
export interface Outcome {
  started: { target: ComparisonTarget; id: string }[];
  failed: { target: ComparisonTarget; message: string }[];
}

/** The session the composer opens: the first one that started. */
export const leader = (o: Outcome): string | null => o.started[0]?.id ?? null;

/** After a send: the model the composer keeps chosen and the extra ones, so trying again only sends what failed. Null
 * when everything started (the composer starts fresh). */
export function retrySelection(o: Outcome): { primary: ComparisonTarget; extras: ComparisonTarget[] } | null {
  if (!o.failed.length) return null;
  const [first, ...rest] = o.failed.map((f) => f.target);
  return { primary: first, extras: rest };
}
