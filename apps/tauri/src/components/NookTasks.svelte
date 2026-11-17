<!-- The Scheduled tab of the Nook list (`NookScheduledList` on the Mac): every task Nook runs on its own, with when it
     runs next. Tasks that will run come first, paused and finished ones after them. A click opens the conversation of
     its latest run (or Settings before its first run); run now and pause sit beside it. -->
<script lang="ts">
  import Icon from "./Icon.svelte";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import { tr } from "../lib/i18n.svelte";
  import type { Target } from "../lib/inbox";
  import { latestRun, nookTasks, openAutomationSettings, splitTasks, taskDetail } from "../lib/nook-tasks";
  import { automationApi, type TaskView } from "../lib/workspace/automation";

  let { tasks, query = "", onopen }: { tasks: TaskView[]; query?: string; onopen?: (target: Target) => void } = $props();

  const shown = $derived(nookTasks(tasks, query));
  const parts = $derived(splitTasks(shown));

  const openSettings = () => openAutomationSettings(onopen);

  async function open(task: TaskView) {
    const run = latestRun(task.id, nook.nooks);
    if (!run) return openSettings();
    try { await nook.select(run.id); }
    catch (e) { toast.error(tr("Kon het gesprek niet openen", "Could not open conversation"), e); }
  }

  async function runNow(task: TaskView) {
    try {
      const result = await automationApi.runNow(task.id);
      if (result === "started") toast.success(tr("‘{title}’ gestart", "Started “{title}”", { title: task.title }));
      if (result === "busy") toast.warning(tr("“{title}” draait al.", "“{title}” is already running.", { title: task.title }));
      if (result === "notAvailable") toast.warning(tr("Zet geplande taken eerst aan.", "Turn on scheduled tasks first."));
    } catch (e) {
      toast.error(tr("Kon de taak niet starten", "Could not start the task"), e);
    }
  }

  async function toggle(task: TaskView) {
    try { await automationApi.setEnabled(task.id, !task.enabled); }
    catch (e) { toast.error(tr("Kon de taak niet aanpassen", "Could not change the task"), e); }
  }
</script>

{#snippet row(task: TaskView)}
  {@const run = latestRun(task.id, nook.nooks)}
  <div class="task" class:active={!!run && run.id === nook.activeId} class:resting={!task.enabled}>
    <button class="open" onclick={() => open(task)} title={run ? tr("Laatste run openen", "Open latest run") : tr("Bewerk", "Edit")}>
      <span class="clock" class:failed={task.lastStatus === "failed"} class:off={!task.enabled}><Icon name={task.enabled ? "clock" : "pause"} size={13} /></span>
      <span class="text">
        <span class="title">{task.title || tr("Taak zonder naam", "Untitled task")}</span>
        <span class="detail">{taskDetail(task)}</span>
      </span>
      {#if task.lastStatus === "failed" && !task.running}<span class="tag failed">{tr("Mislukt", "Failed")}</span>
      {:else if run?.status === "waiting"}<span class="tag waiting">{tr("Wacht op jou", "Needs you")}</span>
      {:else if run?.status === "unread"}<span class="dot unread" aria-label={tr("Nieuw antwoord", "New answer")}></span>{/if}
    </button>
    <span class="row-actions">
      <button class="ghost icon" disabled={task.running} title={tr("Nu draaien", "Run now")} aria-label={tr("Nu draaien", "Run now")} onclick={() => runNow(task)}><Icon name="play" size={12} /></button>
      <button class="ghost icon" title={task.enabled ? tr("Pauzeren", "Pause") : tr("Hervatten", "Resume")} aria-label={task.enabled ? tr("Pauzeren", "Pause") : tr("Hervatten", "Resume")} onclick={() => toggle(task)}><Icon name={task.enabled ? "pause" : "play"} size={12} /></button>
    </span>
  </div>
{/snippet}

<div class="tasks">
  {#if !shown.length && !query.trim()}
    <div class="list-empty">
      <Icon name="clock" size={24} />
      <p>{tr("Nog niets gepland", "Nothing scheduled yet")}</p>
      <span>{tr("Vraag Nook iets op vaste momenten te doen, zoals “geef me elke ochtend om 9:00 een update over mijn berichten”, of voeg hier een taak toe.", "Ask Nook to do something on a schedule, such as “every morning at 9:00, give me an update on my messages”, or add a task here.")}</span>
      <button class="ghost" onclick={openSettings}>{tr("Nieuwe geplande taak", "New scheduled task")}</button>
    </div>
  {:else}
    <h2 class="section-label">
      {tr("Geplande taken ({n})", "Scheduled tasks ({n})", { n: shown.length })}
      <button class="ghost icon" title={tr("Nieuwe geplande taak voor Nook", "New scheduled task for Nook")} aria-label={tr("Nieuwe geplande taak voor Nook", "New scheduled task for Nook")} onclick={openSettings}><Icon name="plus" size={12} /></button>
    </h2>
    {#if !shown.length}<p class="state">{tr("Niets gevonden", "No conversations found")}</p>{/if}
    {#each parts.active as task (task.id)}{@render row(task)}{/each}
    {#if parts.resting.length}
      <h2 class="section-label">{tr("Gepauzeerd en klaar", "Paused and done")}</h2>
      {#each parts.resting as task (task.id)}{@render row(task)}{/each}
    {/if}
  {/if}
</div>

<style>
  .tasks { display: flex; flex-direction: column; gap: var(--space-2); }
  .section-label { display: flex; align-items: center; justify-content: space-between; margin: 0; padding: var(--space-16) 12px var(--space-6); font: var(--text-caption); color: var(--text3); }
  .task { display: flex; align-items: center; border-radius: var(--radius-control); }
  .task:hover { background: var(--row-hover); }
  .task.active { background: var(--row-selected); }
  .open { all: unset; cursor: pointer; flex: 1; min-width: 0; display: flex; align-items: center; gap: var(--space-8); padding: 10px; }
  .open:focus-visible { outline: 2px solid var(--iris); outline-offset: 1px; border-radius: var(--radius-control); }
  .clock { color: var(--iris); display: inline-flex; width: 16px; justify-content: center; }
  .clock.failed { color: var(--coral); }
  .clock.off { color: var(--text3); }
  .text { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: var(--space-2); }
  .title { font: var(--text-label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .resting .title { color: var(--text2); }
  .detail { font: var(--text-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tag { font: var(--text-caption); border-radius: var(--radius-chip); padding: 1px 6px; }
  .tag.failed { color: var(--coral); background: color-mix(in srgb, var(--coral) 14%, transparent); }
  .tag.waiting { color: var(--amber); background: color-mix(in srgb, var(--amber) 14%, transparent); }
  .dot.unread { width: 6px; height: 6px; border-radius: 50%; background: var(--iris); }
  .row-actions { display: none; gap: var(--space-2); padding-right: var(--space-6); }
  .task:hover .row-actions, .task:focus-within .row-actions { display: flex; }
  .icon { padding: 0; width: 24px; min-height: 24px; display: inline-flex; align-items: center; justify-content: center; }
  .list-empty { display: flex; flex-direction: column; align-items: center; text-align: center; padding: 32px 12px; color: var(--text3); }
  .list-empty p { color: var(--text2); margin: 12px 0 6px; font: var(--text-label); }
  .list-empty span { font: var(--text-caption); max-width: 200px; }
  .list-empty button { margin-top: 12px; }
  .state { text-align: center; padding: 16px 10px; color: var(--text2); font: var(--text-detail); }
</style>
