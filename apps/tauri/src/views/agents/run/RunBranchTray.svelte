<script lang="ts">
  // Tray above the session composer (`RunBranchTray` on macOS, AG-104): lists the branches this session has worked
  // on (oldest first, current last) with their pull request status pill and title, folding older branches when the
  // list grows past 4 rows.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import Ico from "../../../components/ui/Ico.svelte";
  import PullGlyph from "../pulls/PullGlyph.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { prSync } from "../../../lib/workspace/pull-requests.svelte";
  import {
    badgeGlyphForLink,
    foldBranchRows,
    type PullRequestLink,
  } from "../../../lib/workspace/pull-requests";
  import { sidePanel } from "./side-panel.svelte";

  let {
    runId,
    directory,
    branch,
  }: {
    runId: string;
    directory: string;
    branch: string | null;
  } = $props();

  let expanded = $state(false);

  const rows = $derived(prSync.branchRowsFor(runId, directory, branch));
  const folded = $derived(foldBranchRows(rows, expanded));

  $effect(() => {
    prSync.start();
    prSync.refresh({ run: runId, directory, branch });
  });

  function openPullRequest(link: PullRequestLink) {
    if (link.host.kind === "github") {
      sidePanel.openTool(runId, "pullRequest");
    } else if (link.url) {
      openUrl(link.url).catch(() => {});
    }
  }
</script>

{#if rows.length > 0}
  <div class="branch-tray" aria-label={tr("Branches en pull requests", "Branches and pull requests")}>
    {#if folded.hiddenCount > 0}
      <button type="button" class="fold-btn" onclick={() => (expanded = true)}>
        <Ico name="chevron-down" size={12} stroke={2.2} />
        <span>
          {#if folded.hiddenPrCount > 0}
            {tr("{n} eerdere branches · {prs} PR's", "{n} earlier branches · {prs} PRs", {
              n: folded.hiddenCount,
              prs: folded.hiddenPrCount,
            })}
          {:else}
            {tr("{n} eerdere branches", "{n} earlier branches", { n: folded.hiddenCount })}
          {/if}
        </span>
      </button>
    {:else if expanded && rows.length > 4}
      <button type="button" class="fold-btn" onclick={() => (expanded = false)}>
        <Ico name="chevron-up" size={12} stroke={2.2} />
        <span>{tr("Verberg eerdere branches", "Hide earlier branches")}</span>
      </button>
    {/if}

    {#each folded.shown as row, idx (`${row.branch ?? ""}-${row.pullRequest?.number ?? idx}`)}
      <div class="tray-row" class:current={row.isCurrent}>
        <span class="branch-cell">
          <Ico name="git-branch" size={12} stroke={2} />
          <span class="branch-name" title={row.branch ?? ""}>
            {row.branch ?? (row.pullRequest ? row.pullRequest.repository : "")}
          </span>
        </span>
        {#if row.pullRequest}
          {@const pr = row.pullRequest}
          {@const g = badgeGlyphForLink(pr)}
          <button
            type="button"
            class="pr-btn {g}"
            title={pr.title || `#${pr.number}`}
            onclick={() => openPullRequest(pr)}
          >
            <span class="pr-glyph">
              {#if g === "conflict"}
                <Ico name="triangle-alert" size={11} stroke={2.3} />
              {:else}
                <PullGlyph glyph={g} size={11} />
              {/if}
            </span>
            <span class="pr-num">#{pr.number}</span>
            {#if pr.title}<span class="pr-title">{pr.title}</span>{/if}
          </button>
        {:else}
          <span class="no-pr">{tr("Geen PR", "No PR")}</span>
        {/if}
      </div>
    {/each}
  </div>
{/if}

<style>
  .branch-tray {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-6) var(--space-8);
    margin-bottom: var(--space-6);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--smoke);
  }
  .fold-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    align-self: flex-start;
    padding: var(--space-2) var(--space-6);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text3);
    font: var(--text-detail);
    cursor: pointer;
  }
  .fold-btn:hover {
    background: var(--row-hover);
    color: var(--paper);
  }
  .tray-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-width: 0;
    padding: var(--space-2) var(--space-4);
    border-radius: var(--radius-chip);
    color: var(--text2);
  }
  .tray-row.current {
    color: var(--paper);
  }
  .branch-cell {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    min-width: 0;
    max-width: 45%;
    flex: 0 1 auto;
    font: var(--text-detail);
  }
  .tray-row.current .branch-name {
    font: var(--text-label);
    color: var(--paper);
  }
  .branch-name {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .pr-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    min-width: 0;
    flex: 1 1 auto;
    padding: var(--space-2) var(--space-6);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text2);
    font: var(--text-detail);
    text-align: left;
    cursor: pointer;
  }
  .pr-btn:hover {
    background: var(--row-hover);
  }
  .pr-glyph {
    display: inline-flex;
    align-items: center;
    flex: none;
  }
  .pr-btn.open .pr-glyph,
  .pr-btn.open .pr-num { color: var(--mint); }
  .pr-btn.draft .pr-glyph,
  .pr-btn.draft .pr-num { color: var(--text3); }
  .pr-btn.conflict .pr-glyph,
  .pr-btn.conflict .pr-num { color: var(--amber); }
  .pr-btn.merged .pr-glyph,
  .pr-btn.merged .pr-num { color: var(--violet); }
  .pr-btn.closed .pr-glyph,
  .pr-btn.closed .pr-num { color: var(--coral); }
  .pr-num {
    font: var(--text-label);
    font-variant-numeric: tabular-nums;
    flex: none;
  }
  .pr-title {
    color: var(--text2);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }
  .tray-row.current .pr-title {
    color: var(--paper);
  }
  .no-pr {
    font: var(--text-detail);
    color: var(--text3);
    padding: var(--space-2) var(--space-6);
  }
</style>
