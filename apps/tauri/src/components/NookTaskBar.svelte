<!-- Over the conversation of a scheduled run (`NookTaskBar` on the Mac): that Nook does this on its own, when it runs
     next, with run now, pause and edit at hand. A task that was removed leaves the conversation as an ordinary one. -->
<script lang="ts">
  import Icon from "./Icon.svelte";
  import { toast } from "../lib/toast.svelte";
  import { tr } from "../lib/i18n.svelte";
  import type { Target } from "../lib/inbox";
  import { openAutomationSettings, taskDetail } from "../lib/nook-tasks";
  import { automationApi, type TaskView } from "../lib/workspace/automation";

  let { taskId, onopen }: { taskId: string; onopen?: (target: Target) => void } = $props();
  let task = $state<TaskView | null>(null);

  $effect(() => {
    const id = taskId;
    let live = true;
    let stop: (() => void) | undefined;
    const load = () => automationApi.overview().then((o) => { if (live) task = o.tasks.find((t) => t.id === id) ?? null; }).catch(() => { if (live) task = null; });
    load();
    automationApi.onChanged(load).then((off) => { if (live) stop = off; else off(); }).catch(() => {});
    return () => { live = false; stop?.(); };
  });

  async function runNow(t: TaskView) {
    try {
      const result = await automationApi.runNow(t.id);
      if (result === "started") toast.success(tr("‘{title}’ gestart", "Started “{title}”", { title: t.title }));
      if (result === "busy") toast.warning(tr("“{title}” draait al.", "“{title}” is already running.", { title: t.title }));
      if (result === "notAvailable") toast.warning(tr("Zet geplande taken eerst aan.", "Turn on scheduled tasks first."));
    } catch (e) {
      toast.error(tr("Kon de taak niet starten", "Could not start the task"), e);
    }
  }

  async function toggle(t: TaskView) {
    try { await automationApi.setEnabled(t.id, !t.enabled); }
    catch (e) { toast.error(tr("Kon de taak niet aanpassen", "Could not change the task"), e); }
  }
</script>

{#if task}
  <div class="bar">
    <span class="clock" class:failed={task.lastStatus === "failed"} class:off={!task.enabled}><Icon name={task.enabled ? "clock" : "pause"} size={13} /></span>
    <span class="text">
      <span class="title">{tr("Nook doet dit uit zichzelf", "Nook does this on its own")}</span>
      <span class="detail">{taskDetail(task)}</span>
    </span>
    <button class="ghost icon" disabled={task.running} title={tr("Nu draaien", "Run now")} aria-label={tr("Nu draaien", "Run now")} onclick={() => task && runNow(task)}><Icon name="play" size={12} /></button>
    <button class="ghost icon" title={task.enabled ? tr("Pauzeren", "Pause") : tr("Hervatten", "Resume")} aria-label={task.enabled ? tr("Pauzeren", "Pause") : tr("Hervatten", "Resume")} onclick={() => task && toggle(task)}><Icon name={task.enabled ? "pause" : "play"} size={12} /></button>
    <button class="ghost icon" title={tr("Bewerk", "Edit")} aria-label={tr("Bewerk", "Edit")} onclick={() => openAutomationSettings(onopen)}><Icon name="pencil" size={12} /></button>
  </div>
{/if}

<style>
  .bar { display: flex; align-items: center; gap: var(--space-8); margin: var(--space-8) 0; padding: var(--space-6) 12px; border: 1px solid var(--line2); border-radius: var(--radius-card); background: var(--surface); }
  .clock { color: var(--iris); display: inline-flex; }
  .clock.failed { color: var(--coral); }
  .clock.off { color: var(--text3); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .title { font: var(--text-label); color: var(--text2); }
  .detail { font: var(--text-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .icon { padding: 0; width: 24px; min-height: 24px; display: inline-flex; align-items: center; justify-content: center; }
</style>
