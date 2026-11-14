<script lang="ts">
  // New session, as the iPhone's sheet (`NewSessionView`): "What should we build in {project}?", the task in a composer
  // with the agent, model, Plan first and Main thread in its row, Current checkout or New worktree under it, and a note
  // that anything risky still waits for your approval. Defaults come from the computer.
  import { untrack } from "svelte";
  import { companion, type ClientView, type LaunchOptions } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NookMark from "./ui/NookMark.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ComposerPill from "./ui/ComposerPill.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Banner from "./ui/Banner.svelte";
  import Ico from "./ui/Ico.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import PhotoButton from "./ui/PhotoButton.svelte";
  import ImageTray from "./ui/ImageTray.svelte";
  import { has, Feature } from "../../lib/companion";

  let { view, task: initial = "", onback, took, onstarted }: {
    view: ClientView;
    task?: string;
    onback: () => void;
    took: (v: ClientView) => void;
    onstarted: (id: string | null) => void;
  } = $props();

  let options = $state<LaunchOptions | null>(null);
  let failed = $state(false);
  let refused = $state<string | null>(null);
  let task = $state(untrack(() => initial));
  let agent = $state("");
  let project = $state("");
  let model = $state("");
  let plan = $state(false);
  let worktree = $state(false);
  let mainThread = $state(false);
  let starting = $state(false);
  let images = $state<string[]>([]);
  let menu = $state<{ anchor: DOMRect; sections: MenuItem[][] } | null>(null);

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
      model = o.agents.find((a) => a.id === agent)?.defaultModel ?? "";
    });
  });

  const chosenAgent = $derived(options?.agents.find((a) => a.id === agent));
  const chosenProject = $derived(options?.projects.find((p) => p.path === project));
  const modelName = $derived(chosenAgent?.models?.find((m) => m.id === model)?.name ?? tr("Model", "Model"));
  const headingParts = $derived(tr("Wat bouwen we in {project}?", "What should we build in {project}?", { project: "\u0000" }).split("\u0000"));
  // The path with the home folder as ~, cut at its start when long (the end says the most).
  const shortPath = (p: string) => {
    const short = p.replace(/^\/(Users|home)\/[^/]+\//, "~/");
    return short.length > 34 ? "…" + short.slice(-33) : short;
  };

  function pick(e: MouseEvent, sections: MenuItem[][]) {
    menu = { anchor: (e.currentTarget as HTMLElement).getBoundingClientRect(), sections };
  }

  async function start(text: string) {
    if (!chosenAgent || !chosenProject || starting) return;
    starting = true;
    refused = null;
    const r = await companion.call({
      op: "start",
      launch: {
        agent: chosenAgent.id, project: chosenProject.path, task: text,
        plan: chosenAgent.canPlan && plan, worktree: chosenProject.canWorktree && worktree,
        model: model || undefined, mainThread: chosenAgent.canMainThread ? mainThread : undefined,
      },
      images: images.length ? images.map((jpeg) => ({ jpeg })) : undefined,
    });
    starting = false;
    if (r.response) {
      haptic("success");
      took(r.view);
      onstarted(r.response.created ?? null);
    } else {
      haptic("warning");
      refused = r.view.notice || tr("Je Mac weigerde dit.", "Your Mac refused this.");
      took({ ...r.view, notice: null });
      companion.clearNotice();
    }
  }
</script>

<div class="new">
  <div class="bar"><button class="cancel" onclick={onback}>{tr("Annuleer", "Cancel")}</button></div>
  <div class="scroll">
    {#if failed}
      <EmptyState icon="wifi-off" title={tr("Je Mac antwoordt niet.", "Your Mac does not answer.")} text={tr("Staat de companion aan, en zit je op hetzelfde wifi?", "Is the companion on, and are you on the same Wi‑Fi?")} />
    {:else if !options}
      <div class="spinner"></div>
    {:else if !options.agents.length}
      <EmptyState icon="layers" title={tr("Er is geen agent klaar op je Mac.", "No agent is ready on your Mac.")} text={tr("Koppel er een in Nook › Instellingen › Agents.", "Connect one in Nook › Settings › Agents.")} />
    {:else if !options.projects.length}
      <EmptyState icon="folder" title={tr("Nog geen mappen.", "No folders yet.")} text={tr("Start één keer een sessie op je Mac: de map verschijnt daarna hier.", "Start a session on your Mac once: its folder then shows up here.")} />
    {:else}
      <NookMark size={44} />
      <button class="heading" onclick={(e) => pick(e, [options!.projects.map((p) => ({ label: p.name, checked: p.path === project, onselect: () => (project = p.path) }))])}>
        {headingParts[0]}<span class="project">{chosenProject?.name}</span>{headingParts[1] ?? ""}
      </button>
      <ImageTray {images} onremove={(i) => (images = images.filter((_, j) => j !== i))} />
      <div class="composer">
        <SessionComposer bind:value={task} placeholder={tr("Wat moet de agent doen?", "What should the agent do?")} minHeight={88} onsend={start} sending={starting} autofocus>
          {#snippet controls()}
            <ComposerPill label={chosenAgent?.name ?? ""} onclick={(e) => pick(e, [options!.agents.map((a) => ({ label: a.name, checked: a.id === agent, onselect: () => { agent = a.id; model = a.defaultModel ?? ""; } }))])}>
              {#snippet lead()}<AgentMark agent={chosenAgent?.name ?? ""} size={16} />{/snippet}
            </ComposerPill>
            {#if (chosenAgent?.models?.length ?? 0) > 1}
              <span class="div"></span>
              <ComposerPill label={modelName} icon="cpu" onclick={(e) => pick(e, [chosenAgent!.models!.map((m) => ({ label: m.name, checked: m.id === model, onselect: () => (model = m.id) }))])} />
            {/if}
            {#if has(view, Feature.images)}
              <span class="div"></span>
              <PhotoButton count={images.length} onpick={(more) => (images = [...images, ...more])} ontoolarge={() => (refused = tr("Die foto kon niet klein genoeg worden gemaakt.", "That picture could not be made small enough."))} />
            {/if}
            {#if chosenAgent?.canPlan}
              <span class="div"></span>
              <ComposerPill label={tr("Eerst plannen", "Plan first")} icon="clipboard-list" chevron={false} on={plan} onclick={() => { haptic(); plan = !plan; }} />
            {/if}
            {#if chosenAgent?.canMainThread}
              <span class="div"></span>
              <ComposerPill label={tr("Hoofdthread", "Main thread")} icon="git-branch" chevron={false} on={mainThread} onclick={() => { haptic(); mainThread = !mainThread; }} />
            {/if}
          {/snippet}
        </SessionComposer>
        <div class="tray">
          {#if chosenProject?.canWorktree}
            <ComposerPill label={worktree ? tr("Nieuwe worktree", "New worktree") : tr("Huidige map", "Current checkout")} icon={worktree ? "layers" : "folder"}
              onclick={(e) => pick(e, [[{ label: tr("Huidige map", "Current checkout"), icon: "folder", checked: !worktree, onselect: () => (worktree = false) }, { label: tr("Nieuwe worktree", "New worktree"), icon: "layers", checked: worktree, onselect: () => (worktree = true) }]])} />
          {:else}
            <ComposerPill label={tr("Huidige map", "Current checkout")} icon="folder" chevron={false} onclick={() => {}} />
          {/if}
          <span class="path">{chosenProject ? shortPath(chosenProject.path) : ""}</span>
        </div>
      </div>
      <p class="note"><Ico name="shield" size={13} />{tr("Nook gebruikt je account, model en rechten voor deze agent. Alles wat riskant is wacht nog steeds op je goedkeuring.", "Nook uses your account, model and permissions for this agent. Anything risky still waits for your approval.")}</p>
      {#if refused}<Banner icon="triangle-alert" tint="var(--coral)">{refused}</Banner>{/if}
    {/if}
  </div>
</div>
{#if menu}<Menu sections={menu.sections} anchor={menu.anchor} onclose={() => (menu = null)} />{/if}

<style>
  .new { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .bar { display: flex; padding: 14px 16px 4px; }
  .cancel { font: 400 17px var(--font) !important; color: var(--paper) !important; min-height: 32px; }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 16px; }
  .heading { text-align: left; font: var(--pt-display) !important; color: var(--paper) !important; }
  .project { text-decoration: underline dotted var(--text3); text-underline-offset: 5px; }
  .composer { position: relative; display: flex; flex-direction: column; }
  .composer > :global(.box) { position: relative; z-index: 1; }
  .div { width: 4px; height: 16px; }
  .tray { display: flex; align-items: center; gap: 8px; margin: -16px 6px 0; padding: 22px 12px 6px; background: var(--composer-tray); border: 1px solid var(--field-stroke); border-top: none; border-radius: 0 0 16px 16px; min-width: 0; }
  .path { flex: 1; min-width: 0; text-align: right; font: var(--pt-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .note { margin: 0; padding: 0 4px; display: flex; align-items: baseline; gap: 6px; font: var(--pt-detail); color: var(--text3); }
  .spinner { align-self: center; margin-top: 60px; width: 28px; height: 28px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
