<script lang="ts">
  // Right side panel beside a session (`SidePanel`, `SidePanelTabBar`, `SessionToolPanel` on macOS, AG-100):
  // sits flat on the canvas to the right of the conversation with a draggable hairline divider, a 32 px tab strip
  // (Plans/Outputs, Subagents, Terminal, Browser, Changes, Pull request, File), `+` to open a tool, hover close cross
  // on each tab, maximize/restore, and an empty-state launcher with keyboard shortcuts.
  import FileViewer from "./FileViewer.svelte";
  import OutputsPanel from "./OutputsPanel.svelte";
  import { collectOutputs } from "../../../lib/workspace/session-outputs";
  import Ico from "../../../components/ui/Ico.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import MarkdownBody from "../../../components/MarkdownBody.svelte";
  import EmptyState from "../EmptyState.svelte";
  import PullRequests from "../pulls/PullRequests.svelte";
  import Terminals from "../../workspace/Terminals.svelte";
  import Browser from "../../workspace/Browser.svelte";
  import Changes from "./Changes.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import { isActive, workspaceApi, type RunEvent, type WorkspaceRun } from "../../../lib/workspace/api";
  import { oneLine } from "../../../lib/workspace/timeline";
  import { SIDE_TOOLS, sidePanel, type SideTool } from "./side-panel.svelte";

  let {
    run,
    events,
    onrun,
    oninitgit,
  }: {
    run: WorkspaceRun;
    events: RunEvent[];
    onrun?: (command: string, title: string | null) => void;
    oninitgit?: () => void;
  } = $props();

  const panel = $derived(sidePanel.forRun(run.id));
  const hasFolder = $derived(!!run.workingDirectory);
  const hasRepo = $derived(!!run.repoRoot);

  // Derived session outputs (plans & changed files) and subagents from the session's live timeline.
  const outputs = $derived(collectOutputs(events, run.tasks, run.workingDirectory));
  const subagents = $derived(
    events.filter((e) => e.kind === "tool" && !e.rolledBack && (e.tool === "Task" || e.tool === "Agent")),
  );
  let openSubagents = $state(new Set<string>());

  // File tab search backed by workspace_files.
  let fileQuery = $state("");
  let fileHits = $state<string[]>([]);
  let fileLoading = $state(false);
  let dragging = $state(false);
  let dragStartX = 0;
  let dragStartWidth = 0;

  $effect(() => {
    if (panel.active !== "file" || !run.workingDirectory) return;
    const root = run.workingDirectory;
    const query = fileQuery.trim();
    let cancelled = false;
    fileLoading = true;
    workspaceApi
      .files(root, query)
      .then((list) => {
        if (!cancelled) fileHits = list;
      })
      .catch(() => {
        if (!cancelled) fileHits = [];
      })
      .finally(() => {
        if (!cancelled) fileLoading = false;
      });
    return () => {
      cancelled = true;
    };
  });

  function available(tool: SideTool): boolean {
    if (tool === "terminal" || tool === "changes") return hasFolder;
    return true;
  }

  function toolTitle(tool: SideTool): string {
    switch (tool) {
      case "outputs":
        return tr("Plannen", "Plans");
      case "subagents":
        return tr("Subagents", "Subagents");
      case "terminal":
        return tr("Terminal", "Terminal");
      case "browser":
        return tr("Browser", "Browser");
      case "changes":
        return tr("Wijzigingen", "Changes");
      case "pullRequest":
        return tr("Pull request", "Pull request");
      case "file":
        return tr("Bestand", "File");
    }
  }

  function toolHelp(tool: SideTool): string {
    switch (tool) {
      case "outputs":
        return tr("Plannen, taken en bestanden die de agent in deze sessie maakte", "Plans, tasks and files the agent made in this session");
      case "subagents":
        return tr("De subagents die de agent startte: hun opdracht, hoe ze te werk gingen en hun antwoord", "The subagents the agent started: their task, how they went about it and their answer");
      case "terminal":
        return tr("Terminal in de map van deze sessie", "Terminal in this session's folder");
      case "browser":
        return tr("Browser naast deze sessie", "Browser next to this session");
      case "changes":
        return tr("Wijzigingen in de map van deze sessie", "Changes in this session's folder");
      case "pullRequest":
        return tr("Een pull request naast deze sessie: die van haar branch, een van jou of uit een link", "A pull request beside this session: the one for its branch, one of yours, or one from a link");
      case "file":
        return tr("Bestanden in de map van deze sessie", "Files in this session's folder");
    }
  }

  function tabLabel(tool: SideTool): string {
    if (tool === "file" && panel.filePath) {
      const base = panel.filePath.replace(/[\\/]+$/, "").split(/[\\/]/).pop();
      if (base) return base;
    }
    return toolTitle(tool);
  }

  function iconOf(tool: SideTool): string {
    return SIDE_TOOLS.find((t) => t.id === tool)?.icon ?? "layout-grid";
  }

  function launch(tool: SideTool) {
    if (!available(tool)) return;
    if (tool === "changes") workspaceApi.markReviewed(run.id).catch(() => {});
    sidePanel.openTool(run.id, tool);
  }

  function toggleSubagent(id: string) {
    const next = new Set(openSubagents);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    openSubagents = next;
  }

  function openInEditor(target: string) {
    workspaceApi.openIn(target).catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e));
  }

  function fullPath(rel: string): string {
    if (!run.workingDirectory) return rel;
    if (rel.startsWith("/") || /^[A-Za-z]:[\\/]/.test(rel)) return rel;
    const sep = run.workingDirectory.includes("\\") ? "\\" : "/";
    return `${run.workingDirectory.replace(/[\\/]+$/, "")}${sep}${rel}`;
  }

  function startResize(e: PointerEvent) {
    if (sidePanel.maximized) return;
    dragging = true;
    dragStartX = e.clientX;
    dragStartWidth = sidePanel.width;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function moveResize(e: PointerEvent) {
    if (!dragging) return;
    sidePanel.setWidth(dragStartWidth + (dragStartX - e.clientX));
  }

  function endResize(e: PointerEvent) {
    if (!dragging) return;
    dragging = false;
    try {
      (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
    } catch {
      // Ignore if capture already released.
    }
  }

  function onLauncherKey(e: KeyboardEvent) {
    if (panel.active !== "picker" || e.metaKey || e.ctrlKey || e.altKey) return;
    const tag = (e.target as HTMLElement | null)?.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || (e.target as HTMLElement | null)?.isContentEditable) return;
    const match = SIDE_TOOLS.find((t) => t.key.toLowerCase() === e.key.toLowerCase());
    if (match && available(match.id)) {
      e.preventDefault();
      launch(match.id);
    }
  }
</script>

<svelte:window onkeydown={onLauncherKey} />

<aside
  class="side-panel"
  class:maximized={sidePanel.maximized}
  class:dragging
  style={sidePanel.maximized ? undefined : `width: ${sidePanel.width}px;`}
  aria-label={tr("Zijpaneel", "Side panel")}
>
  {#if !sidePanel.maximized}
    <!-- Left hairline drag handle (`SidePanel.swift`): drag to resize, double-click resets width. -->
    <div
      class="resize-handle"
      role="separator"
      aria-orientation="vertical"
      aria-label={tr("Zijpaneel breder of smaller maken", "Resize side panel")}
      onpointerdown={startResize}
      onpointermove={moveResize}
      onpointerup={endResize}
      onpointercancel={endResize}
      ondblclick={() => sidePanel.resetWidth()}
    ></div>
  {/if}

  <div class="shell">
    <!-- 32 px top tab bar (`SidePanelTabBar` on macOS): open tabs, `+` add menu, maximize, close. -->
    <div class="tab-bar">
      <div class="tabs" role="tablist">
        {#each panel.tabs as tool (tool)}
          {@const active = panel.active === tool}
          {@const pinned = panel.pinned.includes(tool)}
          <div
            class="tab"
            class:active
            class:pinned
            role="tab"
            tabindex="0"
            aria-selected={active}
            title={toolHelp(tool)}
            onclick={() => sidePanel.selectTab(run.id, tool)}
            onauxclick={(e) => {
              if (e.button === 1) {
                e.preventDefault();
                sidePanel.closeTab(run.id, tool);
              }
            }}
            oncontextmenu={(e) => {
              e.preventDefault();
              sidePanel.togglePin(run.id, tool);
            }}
            onkeydown={(e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                sidePanel.selectTab(run.id, tool);
              }
            }}
          >
            <span class="tab-glyph">
              <span class="tab-icon"><Ico name={iconOf(tool)} size={12} stroke={2} /></span>
              <button
                type="button"
                class="tab-close"
                title={tr("Sluit tabblad", "Close tab")}
                aria-label={tr("Sluit tabblad", "Close tab")}
                onclick={(e) => {
                  e.stopPropagation();
                  sidePanel.closeTab(run.id, tool);
                }}
              >
                <Ico name="x" size={11} stroke={2.4} />
              </button>
            </span>
            <span class="tab-label">{tabLabel(tool)}</span>
            {#if pinned}<span class="pin-mark" aria-hidden="true"><Ico name="pin" size={10} stroke={2.2} /></span>{/if}
          </div>
        {/each}

        <Dropdown width={220} below label={tr("Nieuw tabblad", "New tab")}>
          {#snippet trigger({ toggle, open })}
            <button
              type="button"
              class="bar-btn"
              class:lit={open}
              onclick={toggle}
              aria-expanded={open}
              title={tr("Nieuw tabblad", "New tab")}
              aria-label={tr("Nieuw tabblad", "New tab")}
            >
              <Ico name="plus" size={13} stroke={2.2} />
            </button>
          {/snippet}
          {#snippet children({ close })}
            {#each SIDE_TOOLS as item (item.id)}
              <DropdownRow
                symbol={item.icon}
                title={toolTitle(item.id)}
                chosen={panel.active === item.id}
                disabledReason={available(item.id) ? undefined : tr("Vraagt om een map bij deze sessie", "Needs a folder for this session")}
                onclick={() => {
                  close();
                  launch(item.id);
                }}
              />
            {/each}
          {/snippet}
        </Dropdown>
      </div>

      <div class="bar-trailing">
        <button
          type="button"
          class="bar-btn"
          title={sidePanel.maximized ? tr("Paneel verkleinen", "Restore panel") : tr("Paneel maximaliseren", "Maximize panel")}
          aria-label={sidePanel.maximized ? tr("Paneel verkleinen", "Restore panel") : tr("Paneel maximaliseren", "Maximize panel")}
          onclick={() => sidePanel.toggleMaximized()}
        >
          <Ico name={sidePanel.maximized ? "minimize-2" : "columns-2"} size={13} stroke={2} />
        </button>
        <button
          type="button"
          class="bar-btn"
          title={tr("Zijpaneel sluiten", "Close side panel")}
          aria-label={tr("Zijpaneel sluiten", "Close side panel")}
          onclick={() => sidePanel.close(run.id)}
        >
          <Ico name="x" size={13} stroke={2.2} />
        </button>
      </div>
    </div>

    <!-- Active tool content (or launcher when no tabs are open). Instant switching, no animation lag. -->
    <div class="body">
      {#if panel.active === "picker"}
        <div class="launcher">
          <div class="launcher-inner">
            <span class="launcher-title">{tr("Open een tool", "Open a tool")}</span>
            <div class="launcher-list">
              {#each SIDE_TOOLS as item (item.id)}
                {@const ok = available(item.id)}
                <button
                  type="button"
                  class="launch-row"
                  disabled={!ok}
                  title={ok ? toolHelp(item.id) : tr("Vraagt om een map bij deze sessie", "Needs a folder for this session")}
                  onclick={() => launch(item.id)}
                >
                  <span class="launch-icon"><Ico name={item.icon} size={14} stroke={1.9} /></span>
                  <span class="launch-text">
                    <span class="launch-name">{toolTitle(item.id)}</span>
                    {#if !ok}<span class="launch-reason">{tr("Vraagt om een map bij deze sessie", "Needs a folder for this session")}</span>{/if}
                  </span>
                  <kbd class="launch-key">{item.key}</kbd>
                </button>
              {/each}
            </div>
          </div>
        </div>
      {:else if panel.active === "changes"}
        {#if hasRepo}
          <div class="pane-fill pane-pad">
            {#key run.id}
              <Changes {run} file={panel.changesFile} embedded onclose={() => sidePanel.closeTab(run.id, "changes")} />
            {/key}
          </div>
        {:else}
          <EmptyState
            symbol="folder-git"
            title={tr("Geen git-repository", "No git repository")}
            message={tr("Deze sessie werkt niet in een git-repository. Maak er een git-repository van om wijzigingen en diffs hier te zien.", "This session isn't in a git repository. Make it a git repository to see changes and diffs here.")}
            action={oninitgit ? { title: tr("Maak er een git-repository van", "Make it a git repository"), run: oninitgit } : undefined}
          />
        {/if}
      {:else if panel.active === "terminal"}
        <div class="pane-fill pane-pad">
          {#key run.workingDirectory}
            <Terminals folder={run.workingDirectory} focusId={panel.terminalId} />
          {/key}
        </div>
      {:else if panel.active === "browser"}
        <div class="pane-fill pane-pad">
          <Browser />
        </div>
      {:else if panel.active === "pullRequest"}
        <div class="pane-fill">
          <PullRequests session={run.id} />
        </div>
      {:else if panel.active === "outputs"}
        <OutputsPanel {outputs} selected={panel.outputId} onselect={(id) => sidePanel.setOutput(run.id, id)} folder={run.workingDirectory} live={isActive(run.status)} {onrun} />
      {:else if panel.active === "subagents"}
        <div class="pane-scroll">
          {#if !subagents.length}
            <EmptyState
              symbol="users"
              title={tr("Geen subagents", "No subagents")}
              message={tr("Subagents die de agent tijdens deze sessie start verschijnen hier met hun opdracht en antwoord.", "Subagents the agent starts during this session show up here with their task and answer.")}
            />
          {:else}
            <div class="item-list">
              {#each subagents as agent (agent.id)}
                {@const opened = openSubagents.has(agent.id)}
                <div class="sub-card">
                  <button type="button" class="sub-head" onclick={() => toggleSubagent(agent.id)}>
                    <span class="sub-status {agent.state ?? 'done'}">
                      <Ico
                        name={agent.state === "running" ? "loader-circle" : agent.state === "failed" ? "circle-alert" : "circle-check"}
                        size={13}
                        stroke={2}
                      />
                    </span>
                    <span class="sub-title">{oneLine(agent.text, 120)}</span>
                    <span class="sub-chev" class:open={opened}><Ico name="chevron-right" size={12} stroke={2.2} /></span>
                  </button>
                  {#if opened}
                    {#if agent.detail && agent.detail !== "{}"}
                      <div class="sub-block">
                        <span class="sub-label">{tr("Opdracht", "Task")}</span>
                        <pre class="sub-pre">{agent.detail}</pre>
                      </div>
                    {/if}
                    {#if agent.output}
                      <div class="sub-block">
                        <span class="sub-label">{tr("Antwoord", "Answer")}</span>
                        <pre class="sub-pre">{agent.output}</pre>
                      </div>
                    {:else if agent.state === "running"}
                      <span class="faint-note">{tr("Loopt nog…", "Still running…")}</span>
                    {/if}
                  {/if}
                </div>
              {/each}
            </div>
          {/if}
        </div>
      {:else if panel.active === "file"}
        <div class="file-pane" class:viewing={!!panel.filePath && !fileQuery.trim()}>
          {#if hasFolder}
            <div class="file-search">
              <Ico name="search" size={13} stroke={2} />
              <input
                bind:value={fileQuery}
                placeholder={tr("Zoek bestand in deze map…", "Search file in this folder…")}
                aria-label={tr("Zoek bestand in deze map…", "Search file in this folder…")}
              />
              {#if fileQuery}
                <button type="button" class="clear-btn" aria-label={tr("Wissen", "Clear")} onclick={() => (fileQuery = "")}>
                  <Ico name="x" size={11} stroke={2.4} />
                </button>
              {/if}
            </div>

            {#if panel.filePath && !fileQuery.trim()}
              <FileViewer runId={run.id} path={fullPath(panel.filePath)} line={panel.fileLine ?? undefined} endLine={panel.fileEndLine ?? undefined} opened={panel.fileOpened} folder={run.workingDirectory} />
            {:else}
            <div class="file-list">
              {#if fileLoading && !fileHits.length}
                <span class="faint-note">{tr("Bestanden laden…", "Loading files…")}</span>
              {:else if !fileHits.length}
                <EmptyState
                  symbol="file-text"
                  title={tr("Geen bestand open", "No file open")}
                  message={tr("Klik op een bestandslink in het gesprek, of open zelf een bestand (ook een .env) om het hier te lezen of te bewerken.", "Click a file link in the conversation, or open any file (a .env too) to read or edit it here.")}
                />
              {:else}
                {#each fileHits as rel (rel)}
                  <button
                    type="button"
                    class="list-row"
                    class:picked={panel.filePath === rel}
                    title={rel}
                    onclick={() => sidePanel.setFile(run.id, rel)}
                    ondblclick={() => openInEditor(fullPath(rel))}
                  >
                    <Ico name="file-text" size={13} stroke={1.9} />
                    <span class="mono truncate">{rel}</span>
                  </button>
                {/each}
              {/if}
            </div>
            {/if}
          {:else if panel.filePath}
            <FileViewer runId={run.id} path={panel.filePath} line={panel.fileLine ?? undefined} endLine={panel.fileEndLine ?? undefined} opened={panel.fileOpened} />
          {:else}
            <EmptyState
              symbol="file-text"
              title={tr("Geen bestand open", "No file open")}
              message={tr("Klik op een bestandslink in het gesprek, of open zelf een bestand (ook een .env) om het hier te lezen of te bewerken.", "Click a file link in the conversation, or open any file (a .env too) to read or edit it here.")}
            />
          {/if}
        </div>
      {/if}
    </div>
  </div>
</aside>

<style>
  .side-panel {
    position: relative;
    display: flex;
    flex: none;
    height: 100%;
    min-height: 0;
    min-width: 0;
    background: var(--canvas);
    border-left: 1px solid var(--separator);
  }
  .side-panel.maximized {
    flex: 1 1 auto;
    width: auto;
    border-left: 0;
  }
  .side-panel.dragging {
    user-select: none;
  }

  .resize-handle {
    position: absolute;
    top: 0;
    bottom: 0;
    left: -3px;
    width: 6px;
    cursor: col-resize;
    z-index: 4;
  }
  .resize-handle:hover,
  .side-panel.dragging .resize-handle {
    background: color-mix(in srgb, var(--paper) 18%, transparent);
  }

  .shell {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
    min-height: 0;
  }

  /* 32 px top tab bar matching macOS SidePanelTabBar. */
  .tab-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-4);
    height: 32px;
    padding: 0 var(--space-8);
    border-bottom: 1px solid var(--separator);
    flex: none;
    min-width: 0;
  }
  .tabs {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex: 1;
    min-width: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }
  .tabs::-webkit-scrollbar {
    display: none;
  }

  .tab {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 24px;
    max-width: 168px;
    padding: 0 var(--space-8);
    border-radius: var(--radius-control);
    font: var(--text-label);
    color: var(--text2);
    cursor: pointer;
    flex: none;
    user-select: none;
  }
  .tab:hover {
    background: var(--row-hover);
    color: var(--paper);
  }
  .tab.active {
    background: var(--smoke);
    color: var(--paper);
  }

  .tab-glyph {
    position: relative;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 14px;
    height: 14px;
    flex: none;
  }
  .tab-icon,
  .tab-close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 14px;
    height: 14px;
    padding: 0;
    margin: 0;
    border: 0;
    background: none;
    color: inherit;
    border-radius: var(--radius-chip);
  }
  .tab-close {
    display: none;
  }
  .tab:hover .tab-icon,
  .tab:focus-within .tab-icon {
    display: none;
  }
  .tab:hover .tab-close,
  .tab:focus-within .tab-close {
    display: inline-flex;
    color: var(--text2);
  }
  .tab-close:hover {
    color: var(--paper);
    background: var(--row-selected);
  }
  .tab-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .pin-mark {
    display: inline-flex;
    color: var(--text3);
    flex: none;
  }

  .bar-trailing {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex: none;
  }
  .bar-btn {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text2);
    flex: none;
  }
  .bar-btn:hover,
  .bar-btn.lit {
    background: var(--smoke);
    color: var(--paper);
  }

  .body {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    min-width: 0;
    overflow: hidden;
  }
  .pane-fill {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
    min-width: 0;
  }
  .pane-pad {
    padding: var(--space-12);
  }
  .pane-scroll {
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
    flex: 1;
    min-height: 0;
    overflow: auto;
    padding: var(--space-16);
  }

  /* Empty-state tool launcher matching macOS SidePanelLauncher. */
  .launcher {
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 1;
    padding: var(--space-24);
    overflow: auto;
  }
  .launcher-inner {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    width: 100%;
    max-width: 280px;
  }
  .launcher-title {
    font: var(--text-label);
    color: var(--text3);
    padding: 0 var(--space-8);
  }
  .launcher-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .launch-row {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    width: 100%;
    padding: var(--space-8);
    margin: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--paper);
    text-align: left;
  }
  .launch-row:hover:not(:disabled) {
    background: var(--row-hover);
  }
  .launch-row:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .launch-icon {
    display: inline-flex;
    color: var(--text2);
    flex: none;
  }
  .launch-text {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }
  .launch-name {
    font: var(--text-control);
    color: var(--paper);
  }
  .launch-reason {
    font: var(--text-caption);
    color: var(--text3);
  }
  .launch-key {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 20px;
    height: 20px;
    padding: 0 var(--space-4);
    border: 1px solid var(--line2);
    border-radius: var(--radius-chip);
    background: var(--well);
    font: var(--text-caption);
    color: var(--text3);
    flex: none;
  }

  /* Outputs & Subagents panes */
  .section {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .section-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font: var(--text-label);
    color: var(--text3);
  }
  .count {
    font: var(--text-caption);
    color: var(--text3);
  }
  .pill-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
  }
  .pill {
    padding: var(--space-4) var(--space-8);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: transparent;
    font: var(--text-label);
    color: var(--text2);
  }
  .pill:hover,
  .pill.on {
    background: var(--smoke);
    color: var(--paper);
  }
  .plan-preview {
    padding: var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--surface);
    font: var(--text-body);
    color: var(--text-strong);
  }

  .item-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .list-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    width: 100%;
    padding: var(--space-6) var(--space-8);
    margin: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    font: var(--text-detail);
    text-align: left;
  }
  .list-row:hover,
  .list-row.picked {
    background: var(--row-hover);
    color: var(--paper);
  }
  .mono {
    font-family: var(--mono);
  }
  .truncate {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .badge {
    font: var(--text-caption);
    color: var(--text3);
    flex: none;
  }

  .sub-card {
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--surface);
    overflow: hidden;
  }
  .sub-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    width: 100%;
    padding: var(--space-8) var(--space-12);
    margin: 0;
    border: 0;
    background: transparent;
    color: var(--paper);
    font: var(--text-control);
    text-align: left;
  }
  .sub-head:hover {
    background: var(--row-hover);
  }
  .sub-status {
    display: inline-flex;
    flex: none;
    color: var(--mint);
  }
  .sub-status.running {
    color: var(--amber);
  }
  .sub-status.failed {
    color: var(--coral);
  }
  .sub-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .sub-chev {
    display: inline-flex;
    color: var(--text3);
    flex: none;
  }
  .sub-chev.open {
    transform: rotate(90deg);
  }
  .sub-block {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    padding: var(--space-8) var(--space-12);
    border-top: 1px solid var(--separator);
  }
  .sub-label {
    font: var(--text-caption);
    color: var(--text3);
  }
  .sub-pre {
    margin: 0;
    font: var(--text-code);
    color: var(--text2);
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 260px;
    overflow: auto;
    user-select: text;
  }

  /* File tab */
  .file-pane {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    flex: 1;
    min-height: 0;
    padding: var(--space-12);
  }
  .file-pane.viewing { padding: 0; gap: 0; }
  .file-pane.viewing .file-search { margin: var(--space-8) var(--space-12); }
  .file-search {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-6) var(--space-8);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: var(--field);
    color: var(--text3);
    flex: none;
  }
  .file-search input {
    flex: 1;
    min-width: 0;
    border: 0;
    background: transparent;
    color: var(--paper);
    font: var(--text-detail);
    outline: none;
  }
  .clear-btn {
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text3);
  }
  .clear-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .file-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    flex: 1;
    min-height: 0;
    overflow: auto;
  }
  .faint-note {
    font: var(--text-detail);
    color: var(--text3);
    padding: var(--space-8);
  }
</style>
