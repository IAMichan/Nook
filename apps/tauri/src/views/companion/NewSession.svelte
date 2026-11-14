<script lang="ts">
  // New session, as on the iPhone: type a task, pick a connected agent and one of the folders you recently worked in on
  // the computer, and optionally plan first, work on its own branch (worktree) or start it as a main thread. Account,
  // model and effort come from the computer's remembered choices unless you pick a model it offers.
  import { untrack } from "svelte";
  import { companion, type ClientView, type LaunchOptions } from "../../lib/companion";
  import { onBack } from "../../lib/mobile";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";
  import OnOffSwitch from "../../components/OnOffSwitch.svelte";

  let { view, task: initial = "", onback, took, onstarted }: {
    view: ClientView;
    task?: string;
    onback: () => void;
    took: (v: ClientView) => void;
    onstarted: (id: string | null) => void;
  } = $props();

  let options = $state<LaunchOptions | null>(null);
  let failed = $state(false);
  let task = $state(untrack(() => initial));
  let agent = $state("");
  let project = $state("");
  let model = $state("");
  let plan = $state(false);
  let worktree = $state(false);
  let mainThread = $state(false);
  let starting = $state(false);

  $effect(() => {
    companion.call({ op: "options" }).then((r) => {
      took(r.view);
      const o = r.response?.launch;
      if (!o) return (failed = true);
      options = o;
      agent = o.defaultAgent && o.agents.some((a) => a.id === o.defaultAgent) ? o.defaultAgent : (o.agents[0]?.id ?? "");
      project = o.defaultProject && o.projects.some((p) => p.path === o.defaultProject) ? o.defaultProject : (o.projects[0]?.path ?? "");
      plan = o.defaultPlan;
      worktree = o.defaultWorktree;
    });
  });

  $effect(() => onBack(() => (onback(), true)));

  const chosenAgent = $derived(options?.agents.find((a) => a.id === agent));
  const chosenProject = $derived(options?.projects.find((p) => p.path === project));
  const ready = $derived(!!task.trim() && !!chosenAgent && !!chosenProject && !starting);

  async function start() {
    if (!ready || !chosenAgent || !chosenProject) return;
    starting = true;
    const r = await companion.call({
      op: "start",
      launch: {
        agent: chosenAgent.id,
        project: chosenProject.path,
        task: task.trim(),
        plan: chosenAgent.canPlan && plan,
        worktree: chosenProject.canWorktree && worktree,
        model: model || undefined,
        mainThread: chosenAgent.canMainThread ? mainThread : undefined,
      },
    });
    starting = false;
    took(r.view);
    if (r.response) onstarted(r.response.created ?? null);
  }
</script>

<div class="new">
  <header>
    <button class="ghost back" onclick={onback} aria-label={tr("Terug", "Back")}><Icon name="back" size={20} /></button>
    <h2>{tr("Nieuwe sessie", "New session")}</h2>
    <button class="primary" disabled={!ready} onclick={start}>{starting ? tr("Starten…", "Starting…") : tr("Start", "Start")}</button>
  </header>
  <div class="body">
    {#if failed}
      <p class="faint">{tr("Je computer gaf geen keuzes door. Probeer het zo opnieuw.", "Your computer sent no choices. Try again in a moment.")}</p>
    {:else if !options}
      <p class="faint">{tr("Laden…", "Loading…")}</p>
    {:else if !options.agents.length || !options.projects.length}
      <p class="faint">{tr("Koppel eerst een agent en werk in een map op je computer; dan kun je hier een sessie starten.", "First connect an agent and work in a folder on your computer; then you can start a session here.")}</p>
    {:else}
      <textarea rows="5" placeholder={tr("Wat moet er gebeuren?", "What needs doing?")} bind:value={task}></textarea>
      <label class="field">
        <span class="faint">{tr("Agent", "Agent")}</span>
        <select bind:value={agent} onchange={() => (model = "")}>
          {#each options.agents as a (a.id)}<option value={a.id}>{a.name}</option>{/each}
        </select>
      </label>
      <label class="field">
        <span class="faint">{tr("Map", "Folder")}</span>
        <select bind:value={project}>
          {#each options.projects as p (p.path)}<option value={p.path}>{p.name}</option>{/each}
        </select>
      </label>
      {#if chosenAgent?.models?.length}
        <label class="field">
          <span class="faint">{tr("Model", "Model")}</span>
          <select bind:value={model}>
            <option value="">{tr("Standaard", "Default")}</option>
            {#each chosenAgent.models as m (m.id)}<option value={m.id}>{m.name}</option>{/each}
          </select>
        </label>
      {/if}
      {#if chosenAgent?.canPlan}
        <div class="toggle"><span>{tr("Eerst plannen", "Plan first")}</span><OnOffSwitch on={plan} onchange={(v) => (plan = v)} label={tr("Eerst plannen", "Plan first")} /></div>
      {/if}
      {#if chosenProject?.canWorktree}
        <div class="toggle"><span>{tr("Op een eigen branch (worktree)", "On its own branch (worktree)")}</span><OnOffSwitch on={worktree} onchange={(v) => (worktree = v)} label={tr("Op een eigen branch (worktree)", "On its own branch (worktree)")} /></div>
      {/if}
      {#if chosenAgent?.canMainThread}
        <div class="toggle">
          <span>{tr("Als hoofdlijn", "As a main thread")}<small class="faint">{tr("De agent geeft werk aan sublijnen die terugmelden.", "The agent hands work to sub-threads that report back.")}</small></span>
          <OnOffSwitch on={mainThread} onchange={(v) => (mainThread = v)} label={tr("Als hoofdlijn", "As a main thread")} />
        </div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .new { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-4) var(--space-12) var(--space-4) var(--space-4); border-bottom: 1px solid var(--line); }
  header h2 { flex: 1; margin: 0; font: var(--text-title); }
  header .primary { min-height: 40px; }
  .back { min-width: 44px; min-height: 44px; }
  .body { flex: 1; overflow-y: auto; padding: var(--space-16); display: flex; flex-direction: column; gap: var(--space-12); }
  textarea { resize: none; min-height: 120px; font: var(--text-body); }
  .field { display: flex; flex-direction: column; gap: var(--space-6); font: var(--text-detail); }
  select { min-height: 44px; }
  .toggle { display: flex; align-items: center; justify-content: space-between; gap: var(--space-12); min-height: 44px; font: var(--text-body); }
  .toggle span { display: flex; flex-direction: column; gap: var(--space-2); }
  small { font: var(--text-detail); }
  p { margin: 0; }
</style>
