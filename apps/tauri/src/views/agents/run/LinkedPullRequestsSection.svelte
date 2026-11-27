<script lang="ts">
  // "This session" linked pull requests header inside the session's Pull request side panel (`LinkedPullRequests` on
  // macOS, AG-104): lists PRs from this session's branch, earlier branches, and manually linked PRs with stack
  // indentation, source tags, unlink/dismiss actions, and a "Link pull request" input for URL / `owner/repo#12` / `#12`.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import Ico from "../../../components/ui/Ico.svelte";
  import PullGlyph from "../pulls/PullGlyph.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { prSync } from "../../../lib/workspace/pull-requests.svelte";
  import {
    badgeGlyphForLink,
    linkId,
    sessionKeyFor,
    type LinkedSource,
    type PullRequestLink,
  } from "../../../lib/workspace/pull-requests";

  let {
    runId,
    directory,
    branch,
  }: {
    runId: string;
    directory: string;
    branch: string | null;
  } = $props();

  let adding = $state(false);
  let input = $state("");
  let busy = $state(false);
  let refreshing = $state(false);
  let error = $state<string | null>(null);

  const sessionKey = $derived(sessionKeyFor(runId, directory));
  const linked = $derived(prSync.linkedFor(runId, directory, branch));

  $effect(() => {
    prSync.start();
    prSync.refresh({ run: runId, directory, branch });
  });

  function sourceLabel(source: LinkedSource): string {
    switch (source) {
      case "branch":
        return tr("Van de branch van deze sessie", "From this session's branch");
      case "earlier":
        return tr("Van een eerdere branch van deze sessie", "From an earlier branch of this session");
      case "added":
        return tr("Door jou gekoppeld", "Linked by you");
    }
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    const ref = input.trim();
    if (!ref || busy) return;
    busy = true;
    error = null;
    try {
      await prSync.addLink(sessionKey, directory || null, ref);
      input = "";
      adding = false;
    } catch (err) {
      error = String(err);
    } finally {
      busy = false;
    }
  }

  async function refreshNow() {
    if (refreshing) return;
    refreshing = true;
    try {
      await prSync.refresh({ run: runId, directory, branch }, true);
    } finally {
      refreshing = false;
    }
  }

  function remove(link: PullRequestLink) {
    prSync.removeLink(sessionKey, linkId(link), link.url).catch(() => {});
  }

  function openExternal(url: string) {
    if (url) openUrl(url).catch(() => {});
  }
</script>

<section class="linked-box" aria-label={tr("Deze sessie", "This session")}>
  <div class="linked-head">
    <span class="linked-title">{tr("Deze sessie", "This session")}</span>
    {#if linked.length > 0}<span class="linked-count">{linked.length}</span>{/if}
    <span class="spacer"></span>
    <button
      type="button"
      class="icon-btn"
      title={tr("Vernieuwen", "Refresh")}
      aria-label={tr("Vernieuwen", "Refresh")}
      disabled={refreshing}
      onclick={refreshNow}
    >
      <span class="nook-spin-glyph" class:nook-spin={refreshing}>
        <Ico name="refresh-cw" size={13} stroke={2} />
      </span>
    </button>
    <button
      type="button"
      class="add-btn"
      class:on={adding}
      onclick={() => {
        adding = !adding;
        error = null;
      }}
    >
      <Ico name="link" size={12} stroke={2.1} />
      <span>{tr("Pull request koppelen", "Link pull request")}</span>
    </button>
  </div>

  {#if adding}
    <form class="add-form" onsubmit={submit}>
      <input
        type="text"
        bind:value={input}
        placeholder={tr("Link of nummer", "Link or number")}
        aria-label={tr("Link of nummer", "Link or number")}
        disabled={busy}
      />
      <button type="submit" class="primary-btn" disabled={busy || !input.trim()}>
        {tr("Koppelen", "Link")}
      </button>
    </form>
    {#if error}<p class="err">{error}</p>{/if}
  {/if}

  {#if linked.length > 0}
    <div class="linked-list">
      {#each linked as entry (`${linkId(entry.link)}`)}
        {@const pr = entry.link}
        {@const g = badgeGlyphForLink(pr)}
        <div
          class="linked-row"
          style={entry.depth > 0 ? `padding-left: ${8 + Math.min(entry.depth, 3) * 14}px;` : undefined}
        >
          <span class="glyph {g}">
            {#if g === "conflict"}
              <Ico name="triangle-alert" size={13} stroke={2.2} />
            {:else}
              <PullGlyph glyph={g} size={13} />
            {/if}
          </span>
          <button type="button" class="row-main" onclick={() => openExternal(pr.url)}>
            <span class="row-top">
              <span class="row-num">#{pr.number}</span>
              <span class="row-name">{pr.title || pr.repository}</span>
            </span>
            <span class="row-meta">
              <span>{sourceLabel(entry.source)}</span>
              {#if pr.headBranch}
                <span>·</span>
                <span class="branch-ref">
                  {pr.headBranch}{#if pr.baseBranch} → {pr.baseBranch}{/if}
                </span>
              {/if}
            </span>
          </button>
          <button
            type="button"
            class="row-action"
            title={tr("Open in browser", "Open in browser")}
            aria-label={tr("Open in browser", "Open in browser")}
            onclick={() => openExternal(pr.url)}
          >
            <Ico name="external-link" size={12} stroke={2} />
          </button>
          <button
            type="button"
            class="row-action"
            title={entry.source === "added"
              ? tr("Ontkoppelen van sessie", "Unlink from session")
              : tr("Verbergen in deze sessie", "Dismiss from session")}
            aria-label={entry.source === "added"
              ? tr("Ontkoppelen van sessie", "Unlink from session")
              : tr("Verbergen in deze sessie", "Dismiss from session")}
            onclick={() => remove(pr)}
          >
            <Ico name="x" size={12} stroke={2.2} />
          </button>
        </div>
      {/each}
    </div>
  {:else if !adding}
    <div class="linked-empty">
      <div class="empty-title">{tr("Geen gekoppelde pull requests", "No linked pull requests")}</div>
      <div class="empty-detail">
        {tr(
          "Pull requests die deze sessie opent komen hier. Koppel er zelf een met een link of nummer.",
          "Pull requests this session opens land here. Link one yourself from a link or a number.",
        )}
      </div>
    </div>
  {/if}
</section>

<style>
  .linked-box {
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
    padding: var(--space-8) var(--space-12);
    border-bottom: 1px solid var(--border);
    background: var(--bg);
    flex: none;
  }
  .linked-head {
    display: flex;
    align-items: center;
    gap: var(--space-6);
  }
  .linked-title {
    font: var(--text-label);
    color: var(--text2);
  }
  .linked-count {
    font: var(--text-detail);
    color: var(--text3);
    font-variant-numeric: tabular-nums;
  }
  .spacer {
    flex: 1;
  }
  .icon-btn {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
  }
  .icon-btn:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .add-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 24px;
    padding: 0 var(--space-8);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    font: var(--text-detail);
    cursor: pointer;
  }
  .add-btn:hover,
  .add-btn.on {
    background: var(--smoke);
    color: var(--paper);
  }
  .add-form {
    display: flex;
    align-items: center;
    gap: var(--space-6);
  }
  .add-form input {
    flex: 1;
    min-width: 0;
    height: 28px;
    padding: 0 var(--space-8);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: var(--smoke);
    color: var(--paper);
    font: var(--text-body);
  }
  .add-form input::placeholder {
    color: var(--text3);
  }
  .primary-btn {
    height: 28px;
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-control);
    background: var(--paper);
    color: var(--bg);
    font: var(--text-label);
    cursor: pointer;
    flex: none;
  }
  .primary-btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .err {
    margin: 0;
    font: var(--text-detail);
    color: var(--coral);
  }
  .linked-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .linked-row {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-4) var(--space-6);
    border-radius: var(--radius-chip);
  }
  .linked-row:hover {
    background: var(--row-hover);
  }
  .glyph {
    display: inline-flex;
    align-items: center;
    flex: none;
  }
  .glyph.open { color: var(--mint); }
  .glyph.draft { color: var(--text3); }
  .glyph.conflict { color: var(--amber); }
  .glyph.merged { color: var(--violet); }
  .glyph.closed { color: var(--coral); }
  .row-main {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
    flex: 1;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--paper);
    text-align: left;
    cursor: pointer;
  }
  .row-top {
    display: flex;
    align-items: baseline;
    gap: var(--space-6);
    min-width: 0;
  }
  .row-num {
    font: var(--text-label);
    color: var(--text2);
    font-variant-numeric: tabular-nums;
    flex: none;
  }
  .row-name {
    font: var(--text-body);
    color: var(--paper);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-meta {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    font: var(--text-detail);
    color: var(--text3);
    min-width: 0;
  }
  .branch-ref {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-action {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
    flex: none;
    opacity: 0;
  }
  .linked-row:hover .row-action,
  .row-action:focus-visible {
    opacity: 1;
  }
  .row-action:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .linked-empty {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-4) 0;
  }
  .empty-title {
    font: var(--text-label);
    color: var(--text2);
  }
  .empty-detail {
    font: var(--text-detail);
    color: var(--text3);
  }
</style>
