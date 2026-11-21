<script lang="ts">
  // Een sessie die Nook zelf draait, in de tab Agents (`AgentRunPanel` op de Mac): het hele gesprek, toestemming,
  // stoppen, vervolgberichten en de keuzes voor de volgende beurt. Alles wat je anders in een terminal doet, gebeurt hier.
  import { untrack } from "svelte";
  import { agents } from "../../../lib/agents.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import { ask } from "../../../lib/confirm.svelte";
  import { save as saveDialog } from "@tauri-apps/plugin-dialog";
  import { sessionFileName, sessionMarkdown } from "../../../lib/workspace/session-export";
  import { isActive, isScratch, projectName, toolsApi, workspaceApi, type RunEvent } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { oneLine } from "../../../lib/workspace/timeline";
  import Ico from "../../../components/ui/Ico.svelte";
  import ActionSuggestionBar from "../../../components/ActionSuggestionBar.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import { openNewSessionIn } from "../new-session.svelte";
  import ApprovalCard from "../ApprovalCard.svelte";
  import QuestionCard from "../QuestionCard.svelte";
  import ContextBreakdown from "./ContextBreakdown.svelte";
  import GoalStrip from "./GoalStrip.svelte";
  import RunComposer from "./RunComposer.svelte";
  import SessionSidePanel from "./SessionSidePanel.svelte";
  import { sidePanel } from "./side-panel.svelte";
  import Timeline from "./Timeline.svelte";

  let { runId, ongone }: { runId: string; ongone: () => void } = $props();

  let renaming = $state(false);
  let titleDraft = $state("");
  let revertTarget = $state<RunEvent | null>(null);
  let revertError = $state<string | null>(null);
  let revertRollsBackConversation = $state(false);
  let reverting = $state(false);
  let editTarget = $state<RunEvent | null>(null);
  let editError = $state<string | null>(null);
  let editCanRevertFiles = $state(false);
  let editWorking = $state(false);
  let confirmDelete = $state(false);
  let composer = $state<ReturnType<typeof RunComposer>>();

  const run = $derived(workspace.run(runId));
  const events = $derived(workspace.timelines[runId] ?? []);
  const panel = $derived(sidePanel.forRun(runId));
  const sessionKey = $derived(`run:${runId}`);
  const approvals = $derived(agents.approvals.filter((a) => a.sessionKey === sessionKey));
  const question = $derived(agents.questionFor(sessionKey));
  const showHeaderContext = $derived.by(() => {
    if (!run) return false;
    if (run.compacting) return true;
    const win = run.usage.contextWindow ?? 0;
    const used = run.usage.contextTokens ?? 0;
    if (win <= 0 || used <= 0) return false;
    const frac = used / win;
    const threshold = Math.min(350_000, win * 0.8);
    const pressure = threshold > 0 ? used / threshold : frac;
    return frac > 0.6 || pressure > 0.8;
  });

  // Only another run (or one that just got a repository) loads again: reading the run itself here would re-run this,
  // with a full git refresh, on every workspace update.
  const hasRepo = $derived(!!run?.repoRoot);
  $effect(() => {
    const id = runId;
    const repo = hasRepo;
    untrack(() => {
      workspace.loadTimeline(id);
      if (repo) workspaceApi.git(id, true).catch(() => {});
    });
  });

  const scratch = $derived(isScratch(run?.projectPath));
  /// The agent's newest answer, for the suggested steps above the composer.
  const suggestionTurn = $derived.by(() => {
    const last = [...events].reverse().find((e) => e.kind === "assistant");
    return last ? { conversation: `run:${runId}`, message: last.id, date: last.date } : null;
  });

  // F2 in the Agents tab (`session.rename`): the name field opens in this header.
  $effect(() => {
    const on = (e: Event) => {
      if ((e as CustomEvent<string>).detail === `run:${runId}` && run) { titleDraft = run.title; renaming = true; }
    };
    window.addEventListener("nook-agents-rename", on);
    return () => window.removeEventListener("nook-agents-rename", on);
  });

  // Read every three seconds while the session works and is on screen; nothing is kept.
  let usage = $state<{ cpuPercent: number; memoryBytes: number; processes: number } | null>(null);
  const working = $derived(!!run && isActive(run.status));
  $effect(() => {
    usage = null;
    if (!working) return;
    const id = runId;
    let stopped = false;
    const read = () => workspaceApi.resources(id).then((u) => { if (!stopped && u) usage = u; }).catch(() => {});
    read();
    const timer = setInterval(read, 3000);
    return () => { stopped = true; clearInterval(timer); };
  });

  /// "12 % · 340 MB" (`ResourceUsage.label`).
  function usageLabel(u: { cpuPercent: number; memoryBytes: number }): string {
    const cpu = u.cpuPercent < 10 ? u.cpuPercent.toFixed(1) : String(Math.round(u.cpuPercent));
    const mb = u.memoryBytes / 1_048_576;
    return `${cpu} % · ${mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`}`;
  }
  const kept = $derived(!!run && (workspace.settings?.favoriteProjects ?? []).includes(run.projectPath));

  async function keepScratch() {
    if (!run) return;
    const done = await workspace.act(() => workspaceApi.keepScratch(run!.projectPath));
    if (done !== undefined) toast.success(tr("De map is nu een project", "The folder is a project now"));
  }

  /// "Make it a git repository": git init in its folder, after asking (`agents.scratch.gitInitQuestion`).
  async function initGit() {
    if (!run) return;
    const yes = await ask({
      question: tr("Een git-repository maken in deze map?", "Create a git repository in this folder?"),
      detail: tr("Nook draait git init in {folder}. Branches en diffs werken dan hier ook.", "Nook runs git init in {folder}. Branches and diffs then work here too.", { folder: run.workingDirectory }),
      confirmTitle: tr("Maak git-repository", "Create git repository"),
    });
    if (!yes) return;
    try {
      await workspaceApi.initGit(run.workingDirectory);
      if (!kept) await workspaceApi.keepScratch(run.projectPath).catch(() => {});
      await workspace.refresh();
      toast.success(tr("Git-repository gemaakt", "Git repository created"));
    } catch (e) {
      toast.error(tr("Kon geen git-repository maken", "Couldn't create a git repository"), e);
    }
  }

  /// The session as Markdown (`SessionExport`), copied or saved where you choose.
  function markdown(): string {
    const r = run!;
    return sessionMarkdown(r, events, workspace.provider(r.provider)?.name ?? r.provider, scratch ? tr("Geen project", "No project") : projectName(r.projectPath));
  }

  async function copyMarkdown() {
    try {
      await navigator.clipboard.writeText(markdown());
      toast.success(tr("Sessie gekopieerd", "Session copied"), tr("Tekst gekopieerd als Markdown.", "Text copied as Markdown."));
    } catch (e) {
      toast.error(tr("Kon de sessie niet kopiëren", "Could not copy the session"), e);
    }
  }

  async function exportMarkdown() {
    if (!run) return;
    try {
      const path = await saveDialog({ defaultPath: sessionFileName(run.title), filters: [{ name: "Markdown", extensions: ["md"] }] });
      if (!path) return;
      await workspaceApi.saveMarkdown(path, markdown());
      toast.success(tr("Sessie geëxporteerd", "Session exported"));
    } catch (e) {
      toast.error(tr("Kon de sessie niet exporteren", "Could not export the session"), e);
    }
  }

  async function rename() {
    renaming = false;
    if (titleDraft.trim()) await workspace.act(() => workspaceApi.rename(runId, titleDraft.trim()));
  }

  function canEditEvent(e: RunEvent): boolean {
    if (!run || isActive(run.status)) return false;
    if (!workspace.provider(run.provider)?.capabilities.canRollbackConversation) return false;
    return run.checkpoints.some((c) => c.date <= e.date && !!c.conversation);
  }

  async function askRevert(e: RunEvent) {
    editTarget = null;
    confirmDelete = false;
    revertError = null;
    const [can, canConv] = await Promise.all([
      workspaceApi.canRevert(runId, e.date, false).catch(() => false),
      workspaceApi.canRevert(runId, e.date, true).catch(() => false),
    ]);
    revertRollsBackConversation = canConv;
    revertTarget = e;
    if (!can) revertError = tr("Terugzetten kan alleen bij een sessie in een eigen worktree die niet bezig is.", "Restoring only works for a session in its own worktree that isn't busy.");
  }

  async function revert() {
    if (!revertTarget || reverting || revertError) return;
    reverting = true;
    const rollsBack = revertRollsBackConversation;
    try {
      await workspaceApi.revert(runId, revertTarget.date, false);
      revertTarget = null;
      await workspace.loadTimeline(runId);
      agents.confirm(
        rollsBack
          ? tr("Bestanden en gesprek teruggezet naar een eerder punt. De agent weet niets meer van de latere berichten.", "Files and conversation restored to an earlier point. The agent no longer remembers the later messages.")
          : tr("Bestanden teruggezet naar een eerder punt.", "Files restored to an earlier point."),
      );
    } catch (e) {
      revertError = String(e);
    }
    reverting = false;
  }

  async function askEdit(e: RunEvent) {
    revertTarget = null;
    confirmDelete = false;
    editError = null;
    const [canConv, canFiles] = await Promise.all([
      workspaceApi.canRevert(runId, e.date, true).catch(() => false),
      workspaceApi.canRevert(runId, e.date, false).catch(() => false),
    ]);
    editCanRevertFiles = canFiles;
    editTarget = e;
    if (!canConv) editError = tr("Deze sessie kan niet terug tot vóór dit bericht.", "This session can't go back to before this message.");
  }

  async function editFromHere(revertingFiles: boolean) {
    if (!editTarget || editWorking || editError) return;
    const target = editTarget;
    editWorking = true;
    try {
      await workspaceApi.revert(runId, target.date, !revertingFiles);
      editTarget = null;
      await workspace.loadTimeline(runId);
      composer?.loadEdited(target.text);
      agents.confirm(
        revertingFiles
          ? tr("Bestanden en gesprek teruggezet naar een eerder punt. De agent weet niets meer van de latere berichten.", "Files and conversation restored to an earlier point. The agent no longer remembers the later messages.")
          : tr("Teruggegaan tot vóór je bericht. De bestanden zijn gebleven zoals ze waren.", "Went back to before your message. The files stayed as they were."),
      );
    } catch (e) {
      editError = String(e);
    }
    editWorking = false;
  }

  /// A new session from this one (`fork`): the whole conversation, or up to a message (`keep`), then opened.
  async function fork(keep?: number) {
    const id = await workspace.act(() => workspaceApi.fork(runId, keep));
    if (id) agents.select(`run:${id}`);
  }

  function forkAt(e: RunEvent, through: boolean) {
    const index = events.findIndex((x) => x.id === e.id);
    if (index >= 0) fork(through ? index + 1 : index);
  }

  async function remove() {
    confirmDelete = false;
    const done = await workspace.act(() => workspaceApi.remove(runId));
    if (done !== undefined) ongone();
  }

  async function implement(plan: string) {
    void plan;
    await workspace.act(async () => {
      await workspaceApi.configure(runId, { mode: "agent" });
      await workspaceApi.send(runId, "Voer het plan hierboven uit.");
    });
  }

  function openChanges(file: string | null = null) {
    workspaceApi.markReviewed(runId).catch(() => {});
    sidePanel.openTool(runId, "changes", { changesFile: file });
  }

  function toggleChanges() {
    if (panel.open && panel.active === "changes") {
      sidePanel.close(runId);
    } else {
      openChanges();
    }
  }

  function openFileFromTimeline(path: string) {
    if (run?.repoRoot) openChanges(path);
    else sidePanel.openTool(runId, "file", { filePath: path });
  }

  async function runCode(command: string, title: string | null) {
    if (!run?.workingDirectory) return;
    try {
      if (command) {
        const opened = await toolsApi.openTerminal(run.workingDirectory, command, title);
        sidePanel.openTool(runId, "terminal", { terminalId: opened.id });
      } else {
        sidePanel.openTool(runId, "terminal");
      }
    } catch (e) {
      toast.error(tr("Kon terminal niet openen", "Could not open terminal"), e);
    }
  }
</script>

{#if !run}
  <p class="faint">{tr("Deze sessie bestaat niet meer.", "This session no longer exists.")}</p>
{:else}
  <div class="panel">
    <!-- The session's header (`AgentRunPanel.header`): "project / title ⌄" (the project opens a new session in it, a
         double-click on the name renames it, the chevron holds the session's actions), then on the right the branch
         button and the two panel toggles. -->
    <header class="thread-head">
      {#if scratch}
        <span class="crumb" title={run.workingDirectory}>{tr("Geen project", "No project")}</span>
      {:else}
        <button class="crumb" title={run.workingDirectory} onclick={() => openNewSessionIn(run.projectPath)}>{projectName(run.projectPath)}</button>
      {/if}
      <span class="slash">/</span>
      {#if renaming}
        <!-- svelte-ignore a11y_autofocus -->
        <input class="title-input" bind:value={titleDraft} placeholder={tr("Naam van de sessie", "Session name")} autofocus
          onkeydown={(e) => { if (e.key === "Enter") rename(); if (e.key === "Escape") renaming = false; }} onblur={rename} />
      {:else}
        <span class="title" role="button" tabindex="-1" title={tr("Dubbelklik om de naam te wijzigen", "Double-click to rename")} ondblclick={() => { titleDraft = run.title; renaming = true; }}>{run.title}</span>
        <Dropdown width={248} below label={tr("Meer", "More")}>
          {#snippet trigger({ toggle, open })}
            <button class="head-chev" class:lit={open} onclick={toggle} aria-expanded={open} title={tr("Meer", "More")} aria-label={tr("Meer", "More")}><Ico name="chevron-down" size={11} stroke={2.6} /></button>
          {/snippet}
          {#snippet children({ close })}
            {@const busy = isActive(run.status) ? tr("Stop de agent eerst.", "Stop the agent first.") : undefined}
            {#if isActive(run.status)}
              <DropdownRow symbol="circle-stop" title={tr("Stop", "Stop")} onclick={() => { close(); workspace.act(() => workspaceApi.stop(runId)); }} />
            {:else if run.status === "failed" || run.status === "stopped"}
              <DropdownRow symbol="rotate-ccw" title={tr("Opnieuw", "Retry")} onclick={() => { close(); workspace.act(() => workspaceApi.retry(runId)); }} />
            {/if}
            {#if scratch && !kept}
              <!-- A session started without a project (`SessionPanel.scratchRow`): keep its folder as a project. -->
              <DropdownRow symbol="folder-plus" title={tr("Maak er een project van", "Turn into project")} detail={tr("Deze sessie begon zonder project. Bewaar de map als project en hij staat bij je favorieten.", "This session started without a project. Keep its folder as a project and it shows in your favorites.")}
                onclick={() => { close(); keepScratch(); }} />
            {/if}
            {#if scratch && !run.repoRoot}
              <DropdownRow symbol="folder-git" title={tr("Maak er een git-repository van", "Make it a git repository")} onclick={() => { close(); initGit(); }} />
            {/if}
            <DropdownRow symbol="git-branch" title={tr("Vork maken", "Fork")} disabledReason={busy} onclick={() => { close(); fork(); }} />
            <DropdownRow symbol="pencil" title={tr("Wijzig naam", "Rename")} onclick={() => { close(); titleDraft = run.title; renaming = true; }} />
            {#if run.repoRoot}<DropdownRow symbol="diff" title={tr("Wijzigingen bekijken", "View changes")} onclick={() => { close(); openChanges(); }} />{/if}
            <DropdownRow symbol="external-link" title={tr("Open in editor", "Open in editor")} onclick={() => { close(); workspaceApi.openIn(run.workingDirectory).catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e)); }} />
            <DropdownRow symbol="copy" title={tr("Kopieer als Markdown", "Copy as Markdown")} onclick={() => { close(); copyMarkdown(); }} />
            <DropdownRow symbol="download" title={tr("Exporteer…", "Export…")} onclick={() => { close(); exportMarkdown(); }} />
            <DropdownRow symbol="archive" title={run.archived ? tr("Haal uit archief", "Unarchive") : tr("Archiveer", "Archive")} disabledReason={busy}
              onclick={() => { close(); workspace.act(() => workspaceApi.archive(runId, !run.archived)); }} />
            <DropdownRow symbol="trash-2" title={tr("Verwijder", "Delete")} tint="var(--coral)" disabledReason={busy} onclick={() => { close(); confirmDelete = true; }} />
          {/snippet}
        </Dropdown>
      {/if}
      <span class="spacer"></span>
      {#if showHeaderContext}
        <ContextBreakdown {run} {events} below canCompact={run.provider === "claude" || run.provider === "codex"} />
      {/if}
      {#if usage && isActive(run.status)}
        <!-- `ResourceUsageBadge`: "34 % · 512 MB" while the agent works; amber past three cores. -->
        <span class="resources" class:hot={usage.cpuPercent > 300} title={tr("CPU en geheugen van de agent en wat hij startte", "CPU and memory of the agent and what it started")}>{usageLabel(usage)}</span>
      {/if}
      {#if run.repoRoot}
        <!-- The branch button (`FolderGitButton`): opens or toggles the Changes tab in this session's side panel. -->
        <button class="branch" class:on={panel.open && panel.active === "changes"} title={tr("Wijzigingen bekijken", "View changes")} onclick={toggleChanges}>
          <Ico name="git-branch" size={12} stroke={2.2} /><span class="bname">{run.branch ?? tr("geen branch", "no branch")}</span>{#if run.changedFiles}<span class="files">{run.changedFiles}</span>{/if}{#if run.lastChangeAt && (!run.reviewedAt || run.reviewedAt < run.lastChangeAt) && run.changedFiles}<span class="dot unread"></span>{/if}<Ico name="chevron-down" size={9} stroke={3} />
        </button>
      {/if}
      <!-- The panel toggles (`SessionToolSwitch` on macOS): terminal and the session's right side panel. -->
      <span class="toggles">
        <button class="head-icon" class:on={panel.open && panel.active === "terminal"} disabled={!run.workingDirectory} title={tr("Terminal in de map van deze sessie", "Terminal in this session's folder")} aria-label={tr("Terminal in de map van deze sessie", "Terminal in this session's folder")} onclick={() => runCode("", null)}><Ico name="panel-bottom" size={16} /></button>
        <button class="head-icon" class:on={panel.open} title={panel.open ? tr("Zijpaneel sluiten", "Close side panel") : tr("Zijpaneel openen", "Open side panel")} aria-label={panel.open ? tr("Zijpaneel sluiten", "Close side panel") : tr("Zijpaneel openen", "Open side panel")}
          onclick={() => sidePanel.toggle(runId)}><Ico name="panel-right" size={16} /></button>
      </span>
    </header>

    <div class="workspace-split">
      {#if !(panel.open && sidePanel.maximized)}
        <div class="conversation">
          <Timeline {run} {events} asking={!!question} onrevert={askRevert} onedit={askEdit} canEdit={canEditEvent}
            onretry={() => workspace.act(() => workspaceApi.retry(runId))}
            onimplement={implement} openFile={openFileFromTimeline} onrun={runCode} onfork={forkAt} />

          <div class="thread-column foot">
          {#if approvals.length}
            <ApprovalCard approval={approvals[0]} others={approvals.length - 1} compact />
          {/if}

          {#if editTarget}
            <div class="confirm amber">
              <div class="ctext">
                <strong>{tr("Dit bericht opnieuw schrijven?", "Write this message again?")}</strong>
                <span class:err={!!editError} class:faint={!editError}>
                  {editError ?? (editCanRevertFiles
                    ? tr("Het gesprek gaat terug tot vóór \"{message}\" en het bericht staat weer in het invoerveld. De bestanden kunnen blijven zoals ze nu zijn of mee teruggaan.", "The conversation goes back to before \"{message}\" and the message is back in the composer. The files can stay as they are now or go back too.", { message: oneLine(editTarget.text, 60) })
                    : tr("Het gesprek gaat terug tot vóór \"{message}\" en het bericht staat weer in het invoerveld. De bestanden blijven zoals ze nu zijn.", "The conversation goes back to before \"{message}\" and the message is back in the composer. The files stay as they are now.", { message: oneLine(editTarget.text, 60) }))}
                </span>
              </div>
              <div class="cactions">
                <button class="ghost" onclick={() => (editTarget = null)}>{tr("Annuleer", "Cancel")}</button>
                {#if editCanRevertFiles}
                  <button class="ghost" disabled={!!editError || editWorking} onclick={() => editFromHere(false)}>{tr("Bestanden houden", "Keep file changes")}</button>
                  <button class="primary" disabled={!!editError || editWorking} onclick={() => editFromHere(true)}>{editWorking ? tr("Bezig…", "Restoring…") : tr("Bestanden ook terugzetten", "Revert files too")}</button>
                {:else}
                  <button class="primary" disabled={!!editError || editWorking} onclick={() => editFromHere(false)}>{editWorking ? tr("Bezig…", "Restoring…") : tr("Bewerk vanaf hier", "Edit from here")}</button>
                {/if}
              </div>
            </div>
          {:else if revertTarget}
            <div class="confirm amber">
              <div class="ctext">
                <strong>{tr("Bestanden terugzetten?", "Restore files?")}</strong>
                <span class:err={!!revertError} class:faint={!revertError}>
                  {revertError ?? (revertRollsBackConversation
                    ? tr("De bestanden in deze worktree én het gesprek gaan terug naar hoe ze waren vóór “{message}”. Latere wijzigingen gaan verloren en de agent vergeet de latere berichten.", "The files in this worktree and the conversation go back to how they were before “{message}”. Later changes are lost and the agent forgets the later messages.", { message: oneLine(revertTarget.text, 60) })
                    : tr("De bestanden in deze worktree gaan terug naar hoe ze waren vóór “{message}”. Latere wijzigingen gaan verloren; het gesprek blijft.", "The files in this worktree go back to how they were before “{message}”. Later changes are lost; the conversation stays.", { message: oneLine(revertTarget.text, 60) }))}
                </span>
              </div>
              <div class="cactions">
                <button class="ghost" onclick={() => (revertTarget = null)}>{tr("Annuleer", "Cancel")}</button>
                <button class="primary" disabled={!!revertError || reverting} onclick={revert}>{reverting ? tr("Bezig…", "Restoring…") : tr("Zet terug", "Restore")}</button>
              </div>
            </div>
          {:else if confirmDelete}
            <div class="confirm coral">
              <div class="ctext">
                <strong>{tr("“{title}” verwijderen?", "Delete “{title}”?", { title: run.title })}</strong>
                <span class="faint">{tr("Alleen uit Nook. Je map en bestanden blijven staan.", "Only from Nook. Your folder and files stay where they are.")}</span>
              </div>
              <button class="ghost" onclick={() => (confirmDelete = false)}>{tr("Annuleer", "Cancel")}</button>
              <button class="primary" onclick={remove}>{tr("Verwijder", "Delete")}</button>
            </div>
          {:else if question}
            {#key question.id}<QuestionCard request={question} />{/key}
          {:else}
            <!-- Suggested steps for what the agent just said (`ActionSuggestionBar`, BR-60), above the composer. -->
            <ActionSuggestionBar turn={suggestionTurn} busy={isActive(run.status)} place={{ kind: "agent", name: workspace.provider(run.provider)?.name ?? run.provider, title: run.title }}
              lines={() => events.filter((e) => e.kind === "user" || e.kind === "assistant").slice(-12).map((e) => ({ speaker: e.kind === "user" ? "You" : (workspace.provider(run.provider)?.name ?? run.provider), text: e.text, id: e.id }))} />
            {#if run.goal}
              <GoalStrip runId={run.id} goal={run.goal} />
            {/if}
            <RunComposer bind:this={composer} {run} />
          {/if}
          </div>
        </div>
      {/if}

      {#if panel.open}
        <SessionSidePanel {run} {events} onrun={runCode} oninitgit={!run.repoRoot ? initGit : undefined} />
      {/if}
    </div>
  </div>
{/if}

<style>
  .panel { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .workspace-split { display: flex; flex: 1; min-height: 0; min-width: 0; }
  .conversation { display: flex; flex-direction: column; flex: 1; min-height: 0; min-width: 0; }
  /* 52 px like the window's top row; room on the right for the window's buttons on Windows, and on the left for the
     floating list toggle while the session list is away. */
  .thread-head { display: flex; align-items: center; gap: var(--space-12); min-height: 52px; padding: 0 calc(var(--space-16) + var(--caption-room, 0px)) 0 var(--space-16); font: var(--text-body); flex: none; min-width: 0; }
  :global(.main.list-away) .thread-head { padding-left: calc(var(--space-8) + 28px + var(--space-16)); }
  .crumb { flex: 0 1 auto; min-width: 0; margin: 0; padding: 0; border: 0; background: none; font: var(--text-body); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 200px; }
  .crumb:hover { background: none; color: var(--paper); }
  .slash { color: var(--text3); }
  .title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .head-chev { display: grid; place-items: center; width: 20px; height: 20px; padding: 0; margin: 0; border: 0; border-radius: var(--radius-chip); background: none; color: var(--text3); }
  .head-chev:hover, .head-chev.lit { color: var(--paper); background: none; }
  .resources { font: var(--text-label); font-variant-numeric: tabular-nums; color: var(--text3); white-space: nowrap; }
  .resources.hot { color: var(--amber); }
  .toggles { display: flex; gap: var(--space-2); flex: none; }
  .head-icon { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; margin: 0; flex: none; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .head-icon:hover:not(:disabled), .head-icon.on { background: var(--smoke); color: var(--paper); }
  .head-icon:disabled { opacity: 0.4; }
  .foot { display: flex; flex-direction: column; gap: var(--space-8); padding-bottom: var(--space-16); flex: none; }
  .title-input { flex: 1; padding: 3px 8px; }
  .spacer { flex: 1; }
  .files { font-family: var(--mono); font-size: 11px; color: var(--text3); }
  .branch { display: inline-flex; align-items: center; gap: var(--space-6); height: 26px; padding: 0 7px; margin: 0; border: 0; border-radius: var(--radius-control); background: none; font: var(--text-label); color: var(--text2); min-width: 0; white-space: nowrap; flex-shrink: 1; }
  .branch:hover, .branch.on { background: var(--smoke); color: var(--paper); }
  .branch > :global(svg:last-child) { opacity: 0.5; }
  .bname { flex: 0 1 150px; min-width: 0; width: 150px; text-align: left; overflow: hidden; text-overflow: ellipsis; }
  .confirm { display: flex; flex-wrap: wrap; gap: var(--space-8); align-items: center; padding: var(--space-12); border-radius: var(--radius-composer); border: 1px solid var(--line2); background: var(--surface); }
  .confirm.amber { border-color: color-mix(in srgb, var(--amber) 35%, var(--line2)); }
  .confirm.coral { border-color: color-mix(in srgb, var(--coral) 35%, var(--line2)); }
  .ctext { flex: 1 1 240px; display: flex; flex-direction: column; gap: 2px; font-size: 12px; }
  .ctext strong { font-size: 13px; }
  .cactions { display: flex; flex-wrap: wrap; gap: var(--space-6); align-items: center; flex: none; }
  .err { color: var(--coral); }
</style>
