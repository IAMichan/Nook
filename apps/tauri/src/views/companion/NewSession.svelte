<script lang="ts">
  // New session, as the iPhone's sheet (`NewSessionView`): "What should we build in {project}?", the task in a composer
  // with the agent, model, Plan first and Main thread in its row, Current checkout or New worktree under it, and a note
  // that anything risky still waits for your approval. Defaults come from the computer.
  import { untrack } from "svelte";
  import { companion, MAX_FILE_BYTES, type ClientView, type CompanionFile, type LaunchOptions } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NookMark from "./ui/NookMark.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import ComposerPill from "./ui/ComposerPill.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import EmptyState from "../../components/ui/EmptyState.svelte";
  import Banner from "../../components/ui/Banner.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import PhotoButton from "./ui/PhotoButton.svelte";
  import ImageTray from "./ui/ImageTray.svelte";
  import { has, Feature, writingWaits } from "../../lib/companion";
  import { activeMac, cacheFor, saveSoon } from "../../lib/companion-cache";
  import { agentFor, projectFor, type PromptLink } from "../../lib/prompt-link";

  let { view, task: initial = "", link, onback, took, onstarted }: {
    view: ClientView;
    task?: string;
    /** A prompt link's folder, agent and model, picked when the computer offers them. */
    link?: PromptLink;
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
  // The Agents tab's choices (`agentsTab`): a name, effort, access (never above "allow edits"), base branch, a file.
  let title = $state("");
  let effort = $state("");
  let permission = $state("");
  let baseBranch = $state("");
  let files = $state<CompanionFile[]>([]);
  let filePicker = $state<HTMLInputElement | null>(null);
  const agentsTab = $derived(has(view, Feature.agentsTab));
  async function pickFile() {
    const file = filePicker?.files?.[0];
    if (filePicker) filePicker.value = "";
    if (!file) return;
    const data = await new Promise<string | null>((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
      reader.onerror = () => resolve(null);
      reader.readAsDataURL(file);
    });
    if (!data || Math.floor(data.length * 3 / 4) > MAX_FILE_BYTES) {
      refused = tr("Een bestand van de telefoon mag hoogstens 150 KB zijn.", "A file from the phone can be at most 150 KB.");
      return;
    }
    files = [{ name: file.name, data }];
  }
  let menu = $state<{ anchor: DOMRect; sections: MenuItem[][] } | null>(null);

  const offline = $derived(view.phase === "offline");
  $effect(() => {
    companion.call({ op: "options" }).then((r) => {
      took(r.view);
      // What the computer offered last time, while it cannot be reached: the session can be written and wait.
      const mac = activeMac(r.view);
      const cache = cacheFor(mac);
      if (r.response?.launch && cache) { cache.launch = r.response.launch; saveSoon(mac); }
      const o = r.response?.launch ?? (r.view.phase === "offline" ? cache?.launch : undefined);
      if (!o) return (failed = true);
      options = o;
      agent = o.defaultAgent && o.agents.some((a) => a.id === o.defaultAgent) ? o.defaultAgent : (o.agents[0]?.id ?? "");
      project = o.defaultProject && o.projects.some((p) => p.path === o.defaultProject) ? o.defaultProject : (o.projects[0]?.path ?? "");
      const named = agentFor(link?.agent, o.agents);
      if (named) agent = named.id;
      const folder = projectFor(link?.project, o.projects);
      if (folder) project = folder.path;
      plan = o.defaultPlan;
      worktree = o.defaultWorktree;
      const chosen = o.agents.find((a) => a.id === agent);
      model = link?.model && chosen?.models?.some((m) => m.id === link.model) ? link.model : (chosen?.defaultModel ?? "");
      effort = chosen?.defaultEffort ?? "";
      permission = chosen?.defaultPermission ?? "";
      baseBranch = o.projects.find((p) => p.path === project)?.defaultBase ?? "";
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

  const choicesWord = $derived.by(() => {
    const parts = [effort ? chosenAgent?.efforts?.find((x) => x.id === effort)?.name : undefined,
      chosenAgent?.permissions?.find((x) => x.id === permission)?.name].filter(Boolean);
    return parts.length ? parts.join(" · ") : tr("Opties", "Options");
  });

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
        title: agentsTab && title.trim() ? title.trim() : undefined,
        effort: agentsTab && chosenAgent.efforts ? effort : undefined,
        permission: agentsTab && chosenAgent.permissions && permission && !plan ? permission : undefined,
        baseBranch: agentsTab && worktree && chosenProject.branches?.includes(baseBranch) ? baseBranch : undefined,
      },
      images: images.length ? images.map((jpeg) => ({ jpeg })) : undefined,
      attachments: agentsTab && files.length ? files : undefined,
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
      <button class="heading" onclick={(e) => pick(e, [options!.projects.map((p) => ({ label: p.name, checked: p.path === project, onselect: () => { project = p.path; baseBranch = p.defaultBase ?? ""; } }))])}>
        {headingParts[0]}<span class="project">{chosenProject?.name}</span>{headingParts[1] ?? ""}
      </button>
      {#if offline}
        <Banner icon="wifi-off">{writingWaits(view)
          ? tr("Offline: de sessie start nog niet. Hij wacht op deze telefoon en start zodra je Mac terug is.", "Offline: the session does not start yet. It waits on this phone and starts as soon as your Mac is back.")
          : tr("Offline: maak verbinding met je Mac om een sessie te starten.", "Offline: connect to your Mac to start a session.")}</Banner>
      {/if}
      {#if agentsTab}<input class="name" bind:value={title} placeholder={tr("Naam (optioneel)", "Name (optional)")} />{/if}
      <ImageTray {images} onremove={(i) => (images = images.filter((_, j) => j !== i))} />
      {#each files as f, i (f.name)}
        <span class="filechip"><Ico name="file" size={13} /><span>{f.name}</span><button aria-label={tr("Bestand verwijderen", "Remove file")} onclick={() => (files = files.filter((_, j) => j !== i))}><Ico name="x" size={10} stroke={3} /></button></span>
      {/each}
      <div class="composer">
        <SessionComposer bind:value={task} placeholder={tr("Wat moet de agent doen?", "What should the agent do?")} minHeight={88} onsend={start} sending={starting} canSend={!offline || writingWaits(view)} autofocus>
          {#snippet controls()}
            <ComposerPill label={chosenAgent?.name ?? ""} onclick={(e) => pick(e, [options!.agents.map((a) => ({ label: a.name, checked: a.id === agent, onselect: () => { agent = a.id; model = a.defaultModel ?? ""; effort = a.defaultEffort ?? ""; permission = a.defaultPermission ?? ""; } }))])}>
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
            {#if agentsTab && has(view, "attachments")}
              <span class="div"></span>
              <ComposerPill label={tr("Bestand", "File")} icon="paperclip" chevron={false} onclick={() => filePicker?.click()} />
              <input bind:this={filePicker} type="file" hidden onchange={pickFile} />
            {/if}
            {#if agentsTab && ((chosenAgent?.efforts?.length ?? 0) > 1 || (chosenAgent?.permissions?.length ?? 0) > 1)}
              <span class="div"></span>
              <ComposerPill label={choicesWord} icon="cpu" onclick={(e) => pick(e, [
                (chosenAgent?.efforts ?? []).map((x) => ({ label: x.name, detail: tr("Inspanning", "Effort"), checked: x.id === effort, onselect: () => (effort = x.id) })),
                plan ? [] : (chosenAgent?.permissions ?? []).map((x) => ({ label: x.name, detail: tr("Toegang", "Access"), checked: x.id === permission, onselect: () => (permission = x.id) })),
              ])} />
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
          {#if agentsTab && worktree && (chosenProject?.branches?.length ?? 0) > 1}
            <ComposerPill label={baseBranch || (chosenProject?.defaultBase ?? "")} icon="git-branch"
              onclick={(e) => pick(e, [(chosenProject?.branches ?? []).map((b) => ({ label: b, checked: b === baseBranch, onselect: () => (baseBranch = b) }))])} />
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
  .name { font: var(--pt-body); color: var(--paper); background: var(--field); border: none; border-radius: 10px; min-height: 44px; padding: 0 14px; }
  .filechip { align-self: flex-start; display: inline-flex; align-items: center; gap: 6px; padding: 4px 6px 4px 10px; background: var(--field); border-radius: 8px; font: var(--pt-label); color: var(--paper); }
  .filechip button { width: 20px; height: 20px; border-radius: 50%; background: var(--smoke) !important; display: inline-flex; align-items: center; justify-content: center; color: var(--text2) !important; }
  .note { margin: 0; padding: 0 4px; display: flex; align-items: baseline; gap: 6px; font: var(--pt-detail); color: var(--text3); }
  .spinner { align-self: center; margin-top: 60px; width: 28px; height: 28px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
