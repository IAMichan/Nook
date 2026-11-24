<script lang="ts">
  // Above a conversation's field: what Nook could do for what was just said (`ActionSuggestionBar` on the Mac). Before
  // you act, `WhisperSuggestion`: one quiet line on a dashed outline that turns solid on hover (the steps, "Adjust first"
  // for a new session, Do it and the cross; why Nook proposes it as the tip, the steps in full on a click). Once it runs,
  // `DraftActions` on its own card: the sparkles badge, the title and why, each step with its badge, and how it went.
  // It asks for a look whenever the newest message (`turn`) or `busy` changes.
  import { untrack } from "svelte";
  import { emit } from "@tauri-apps/api/event";
  import { tr } from "../lib/i18n.svelte";
  import { actionSuggestions, type Line, type Place, type SuggestedStep, type Turn } from "../lib/action-suggestions.svelte";
  import { agents } from "../lib/agents.svelte";
  import { nook } from "../lib/state.svelte";
  import { workspace } from "../lib/workspace/store.svelte";
  import { openNewSessionIn } from "../views/agents/new-session.svelte";
  import Ico from "./ui/Ico.svelte";
  import IconButton from "./ui/IconButton.svelte";

  let { turn, busy = false, place, lines, nookId = null, enabled = nook.settings?.suggestChatActions !== false, onadjust }: {
    turn: Turn | null; busy?: boolean; place: Place; lines: () => Line[]; nookId?: string | null; enabled?: boolean;
    /** Shows the Agents tab, where "Adjust first" opens the new-session composer; without it the navigate event does. */
    onadjust?: () => void;
  } = $props();

  let expanded = $state(false);
  const conversation = $derived(turn?.conversation ?? "");
  const shown = $derived(conversation ? actionSuggestions.shown(conversation) : null);
  const many = (n: number) => tr("{n} acties uitgevoerd", "{n} actions completed", { n });

  $effect(() => {
    const t = turn, b = busy, on = enabled;
    untrack(() => actionSuggestions.request(t, b, place, lines, on));
  });
  $effect(() => {
    void conversation;
    expanded = false;
  });

  /// The one step "Adjust first" applies to: a single new session waiting for your click.
  const adjustable = $derived(
    shown && shown.run.kind === "waiting" && shown.actions.length === 1 && shown.actions[0].tool === "start_agent_session" ? shown.actions[0] : null,
  );

  /// "Adjust first": the new-session composer on the step's project, with its task in the box to read and change.
  async function adjust(step: SuggestedStep) {
    const input = (step.input ?? {}) as { task?: string; folder?: string };
    const folder = (input.folder ?? "").trim().toLowerCase();
    const settings = workspace.settings;
    const known = [...(settings?.favoriteProjects ?? []), ...(settings?.recentProjects ?? [])];
    const path = known.find((p) => p.replace(/[\\/]+$/, "").split(/[\\/]/).pop()?.toLowerCase() === folder) ?? known.find((p) => p.toLowerCase() === folder);
    actionSuggestions.dismiss(conversation);
    agents.select("new");
    // The Agents tab: the caller shows it, else the main window's own navigate event does (a chat in the Chats tab).
    if (onadjust) onadjust();
    else emit("navigate", "agents").catch(() => {});
    if (!path) return;
    try { localStorage.setItem(`nook.newSession.draft:${path.replace(/[\\/]+$/, "")}`, (input.task ?? "").trim()); } catch { /* opens without the task */ }
    await openNewSessionIn(path);
  }

  /// A symbol for the kind of step (`ChatDraftAction.symbol`).
  function symbol(tool: string): string {
    if (tool.includes("reminder")) return "bell";
    if (tool.includes("event")) return "calendar-plus";
    if (tool.includes("mail")) return "mail";
    if (tool.includes("note")) return "notebook-text";
    if (tool.includes("send") || tool.includes("message")) return "send";
    return "sparkles";
  }
</script>

{#if shown && shown.run.kind === "waiting"}
  <div class="whisper" class:expanded role="group" aria-label={tr("Nook stelt voor", "Nook suggests")}>
    <span class="mark"><Ico name="sparkles" size={13} stroke={2.4} /></span>
    <button class="steps" title={expanded ? undefined : (shown.reason ?? undefined)} aria-expanded={expanded} onclick={() => (expanded = !expanded)}>
      {#each shown.actions as step, i (i)}<span class="step">{step.summary}</span>{/each}
      {#if expanded && shown.reason}<span class="reason">{shown.reason}</span>{/if}
    </button>
    {#if adjustable}
      <button class="ghost-button" onclick={() => adjust(adjustable)}>{tr("Eerst aanpassen", "Adjust first")}</button>
    {/if}
    <button class="ghost-button" onclick={() => actionSuggestions.run(conversation, nookId, many)}><Ico name="check" size={13} stroke={2.6} />{tr("Uitvoeren", "Do it")}</button>
    <IconButton title={tr("Laat dit voorstel gaan", "Let this proposal go")} size={26} onclick={() => actionSuggestions.dismiss(conversation)}><Ico name="x" size={13} /></IconButton>
  </div>
{:else if shown}
  <div class="card" role="status">
    <div class="head">
      <span class="badge round"><Ico name="sparkles" size={13} stroke={2.4} /></span>
      <span class="titles">
        <span class="title">{tr("Nook stelt voor", "Nook suggests")}</span>
        {#if shown.reason}<span class="reason">{shown.reason}</span>{/if}
      </span>
      {#if shown.run.kind !== "running"}
        <IconButton title={shown.run.kind === "done" ? tr("Sluiten", "Close") : tr("Laat dit voorstel gaan", "Let this proposal go")} size={26} onclick={() => actionSuggestions.dismiss(conversation)}><Ico name="x" size={13} /></IconButton>
      {/if}
    </div>
    <div class="rows">
      {#each shown.actions as step, i (i)}
        <div class="row" class:done={shown.run.kind === "done"}>
          <span class="badge"><Ico name={shown.run.kind === "done" ? "check" : symbol(step.tool)} size={12} stroke={2.6} /></span>
          <span class="step-text">{step.summary}</span>
        </div>
      {/each}
    </div>
    {#if shown.run.kind === "running"}
      <div class="state"><span class="spinner" aria-hidden="true"></span><span>{tr("Bezig…", "Running…")}</span></div>
    {:else if shown.run.kind === "done"}
      <div class="state done"><Ico name="check" size={13} stroke={2.6} /><span>{shown.run.text}</span></div>
    {:else if shown.run.kind === "failed"}
      <div class="state failed"><Ico name="triangle-alert" size={13} /><span>{shown.run.text}</span></div>
    {/if}
  </div>
{/if}

<style>
  /* `WhisperSuggestion`: a quiet line on the composer tray's fill, dashed until the pointer is on it. */
  .whisper { display: flex; align-items: center; gap: var(--space-6); margin: 0 0 var(--space-8); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); background: var(--composer-tray); border: 1px dashed var(--field-stroke); border-radius: var(--radius-sheet); transition: border-color var(--motion-hover); }
  .whisper:hover, .whisper.expanded { border-style: solid; }
  .whisper.expanded { align-items: flex-start; }
  .mark { display: inline-flex; color: var(--text3); flex: none; transition: color var(--motion-hover); }
  .whisper:hover .mark { color: var(--iris); }
  .steps { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); padding: 0; border: 0; background: transparent; text-align: left; }
  .step { font: var(--text-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .whisper:hover .step, .whisper.expanded .step { color: var(--text-strong); }
  .expanded .step { display: block; }
  .reason { font: var(--text-caption); color: var(--text3); }
  /* `NookGhostButton(compact:)`: no outline, 13 pt semibold, a fill on hover, 28 pt tall. */
  .ghost-button { display: inline-flex; align-items: center; gap: var(--space-6); flex: none; height: 28px; padding: 0 var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); font: var(--text-control); font-weight: 600; white-space: nowrap; }
  .ghost-button:hover { background: var(--graphite); color: var(--paper); }
  /* `DraftActions(standalone:)` on its own card. */
  .card { display: flex; flex-direction: column; gap: var(--space-8); margin: 0 0 var(--space-8); padding: var(--space-12); background: var(--composer-tray); border: 1px solid var(--field-stroke); border-radius: var(--radius-sheet); }
  .head { display: flex; align-items: flex-start; gap: var(--space-6); }
  .badge { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; flex: none; border-radius: var(--radius-chip); color: var(--iris); background: color-mix(in srgb, var(--iris) 12%, transparent); }
  .badge.round { border-radius: 999px; background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .titles { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .title { min-height: 22px; display: inline-flex; align-items: center; font: var(--text-emphasis); color: var(--paper); }
  .rows { display: flex; flex-direction: column; gap: var(--space-6); }
  .row { display: flex; align-items: flex-start; gap: var(--space-6); }
  .row.done .badge { color: var(--mint); background: color-mix(in srgb, var(--mint) 12%, transparent); }
  .step-text { min-height: 22px; display: flex; align-items: center; font: var(--text-detail); color: var(--text-strong); }
  .state { display: flex; align-items: center; gap: var(--space-6); font: var(--text-label); color: var(--text2); }
  .state.done { font: var(--text-detail); color: var(--mint); }
  .state.failed { font: var(--text-detail); color: var(--coral); }
  .spinner { width: 12px; height: 12px; border-radius: 999px; border: 2px solid var(--line2); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
