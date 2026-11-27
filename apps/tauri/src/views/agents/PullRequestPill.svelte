<script lang="ts">
  // Compact PR status pill (`PullRequestBadge` on macOS, AG-104) shown in session rows with a hover card
  // listing the session's current, stacked, and earlier pull requests.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import Ico from "../../components/ui/Ico.svelte";
  import PullGlyph from "./pulls/PullGlyph.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import {
    badgeGlyphForLink,
    orderStack,
    type BadgeGlyph,
    type PullRequestBadge,
    type PullRequestLink,
  } from "../../lib/workspace/pull-requests";

  let {
    badge,
    current = [],
    earlier = [],
    onopen,
  }: {
    badge: PullRequestBadge;
    current?: PullRequestLink[];
    earlier?: PullRequestLink[];
    onopen?: (link: PullRequestLink) => void;
  } = $props();

  let open = $state(false);
  let anchor = $state<HTMLSpanElement | null>(null);
  let cardStyle = $state("");
  let closeTimer: ReturnType<typeof setTimeout> | null = null;

  const stackedCurrent = $derived(orderStack(current));
  const stackedEarlier = $derived(orderStack(earlier));

  function badgeText(b: PullRequestBadge): string {
    switch (b.label.kind) {
      case "number":
        return `#${b.label.number}`;
      case "numberPlus":
        return `#${b.label.number} +${b.label.extra}`;
      case "stack":
        if (b.label.merged > 0) {
          return tr("{merged} van {count} gemerged", "{merged} of {count} merged", {
            merged: b.label.merged,
            count: b.label.count,
          });
        }
        return tr("Stapel van {n}", "Stack of {n}", { n: b.label.count });
    }
  }

  function stateLabel(glyph: BadgeGlyph): string {
    switch (glyph) {
      case "open":
        return tr("Open, klaar om te mergen", "Open, ready to merge");
      case "draft":
        return tr("Concept", "Draft");
      case "conflict":
        return tr("Mergeconflict", "Merge conflict");
      case "merged":
        return tr("Gemerged", "Merged");
      case "closed":
        return tr("Gesloten", "Closed");
      case "stack":
        return tr("Gestapelde pull requests", "Stacked pull requests");
    }
  }

  function positionCard() {
    if (!anchor) return;
    const rect = anchor.getBoundingClientRect();
    const cardW = 300;
    const left = Math.min(Math.max(8, rect.right + 8), Math.max(8, window.innerWidth - cardW - 12));
    const top = Math.min(Math.max(8, rect.top - 6), Math.max(8, window.innerHeight - 260));
    cardStyle = `left: ${Math.round(left)}px; top: ${Math.round(top)}px;`;
  }

  function show() {
    if (closeTimer) {
      clearTimeout(closeTimer);
      closeTimer = null;
    }
    positionCard();
    open = true;
  }

  function scheduleHide() {
    if (closeTimer) clearTimeout(closeTimer);
    closeTimer = setTimeout(() => {
      open = false;
      closeTimer = null;
    }, 120);
  }

  function handleOpen(link: PullRequestLink, e: MouseEvent) {
    e.stopPropagation();
    open = false;
    if (onopen) {
      onopen(link);
    } else if (link.url) {
      openUrl(link.url).catch(() => {});
    }
  }

  function handlePillClick(e: MouseEvent) {
    e.stopPropagation();
    const target = current[0] ?? earlier[0];
    if (target) handleOpen(target, e);
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<span
  class="pr-pill-wrap"
  bind:this={anchor}
  onmouseenter={show}
  onmouseleave={scheduleHide}
>
  <span
    class="pr-pill {badge.glyph}"
    role="button"
    tabindex="0"
    title={stateLabel(badge.glyph)}
    onclick={handlePillClick}
    onkeydown={(e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        const target = current[0] ?? earlier[0];
        if (target) {
          open = false;
          if (onopen) onopen(target);
          else if (target.url) openUrl(target.url).catch(() => {});
        }
      }
    }}
  >
    {#if badge.glyph === "conflict"}
      <Ico name="triangle-alert" size={11} stroke={2.3} />
    {:else if badge.glyph === "stack"}
      <Ico name="layers" size={11} stroke={2.2} />
    {:else}
      <PullGlyph glyph={badge.glyph} size={11} />
    {/if}
    <span class="pill-text">{badgeText(badge)}</span>
  </span>

  {#if open && (stackedCurrent.length > 0 || stackedEarlier.length > 0)}
    <div
      class="hover-card"
      style={cardStyle}
      role="dialog"
      tabindex="-1"
      aria-label="Pull requests"
      onmouseenter={show}
      onmouseleave={scheduleHide}
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => {
        if (e.key === "Escape") {
          e.stopPropagation();
          open = false;
        }
      }}
    >
      {#if stackedCurrent.length > 0}
        <div class="card-group">
          {#each stackedCurrent as entry (`cur-${entry.link.repository}-${entry.link.number}`)}
            {@const g = badgeGlyphForLink(entry.link)}
            <button
              type="button"
              class="card-row"
              style={entry.depth > 0 ? `padding-left: ${8 + Math.min(entry.depth, 3) * 14}px;` : undefined}
              onclick={(e) => handleOpen(entry.link, e)}
            >
              <span class="row-glyph {g}" title={stateLabel(g)}>
                {#if g === "conflict"}
                  <Ico name="triangle-alert" size={13} stroke={2.2} />
                {:else}
                  <PullGlyph glyph={g} size={13} />
                {/if}
              </span>
              <span class="row-body">
                <span class="row-top">
                  <span class="row-num">#{entry.link.number}</span>
                  <span class="row-title">{entry.link.title || entry.link.repository}</span>
                </span>
                {#if entry.link.headBranch}
                  <span class="row-branches">
                    <span class="branch-name">{entry.link.headBranch}</span>
                    {#if entry.link.baseBranch}
                      <span class="arrow">→</span>
                      <span class="branch-name">{entry.link.baseBranch}</span>
                    {/if}
                  </span>
                {/if}
              </span>
            </button>
          {/each}
        </div>
      {/if}

      {#if stackedEarlier.length > 0}
        {#if stackedCurrent.length > 0}<div class="card-sep"></div>{/if}
        <div class="card-group">
          <div class="card-heading">{tr("Eerdere pull requests", "Earlier pull requests")}</div>
          {#each stackedEarlier as entry (`ear-${entry.link.repository}-${entry.link.number}`)}
            {@const g = badgeGlyphForLink(entry.link)}
            <button
              type="button"
              class="card-row earlier"
              style={entry.depth > 0 ? `padding-left: ${8 + Math.min(entry.depth, 3) * 14}px;` : undefined}
              onclick={(e) => handleOpen(entry.link, e)}
            >
              <span class="row-glyph {g}" title={stateLabel(g)}>
                {#if g === "conflict"}
                  <Ico name="triangle-alert" size={13} stroke={2.2} />
                {:else}
                  <PullGlyph glyph={g} size={13} />
                {/if}
              </span>
              <span class="row-body">
                <span class="row-top">
                  <span class="row-num">#{entry.link.number}</span>
                  <span class="row-title">{entry.link.title || entry.link.repository}</span>
                </span>
                {#if entry.link.headBranch}
                  <span class="row-branches">
                    <span class="branch-name">{entry.link.headBranch}</span>
                  </span>
                {/if}
              </span>
            </button>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</span>

<style>
  .pr-pill-wrap {
    position: relative;
    display: inline-flex;
    align-items: center;
    flex: none;
  }
  .pr-pill {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    height: 18px;
    padding: 0 var(--space-6);
    border-radius: 999px;
    font: var(--text-detail);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    cursor: pointer;
    background: var(--smoke);
    color: var(--text2);
  }
  .pr-pill:hover {
    background: var(--row-hover);
  }
  .pr-pill.open {
    color: var(--mint);
    background: color-mix(in srgb, var(--mint) 12%, transparent);
  }
  .pr-pill.draft {
    color: var(--text2);
    background: var(--smoke);
  }
  .pr-pill.conflict {
    color: var(--amber);
    background: color-mix(in srgb, var(--amber) 14%, transparent);
  }
  .pr-pill.merged {
    color: var(--violet);
    background: color-mix(in srgb, var(--violet) 12%, transparent);
  }
  .pr-pill.closed {
    color: var(--coral);
    background: color-mix(in srgb, var(--coral) 12%, transparent);
  }
  .pr-pill.stack {
    color: var(--blue);
    background: color-mix(in srgb, var(--blue) 12%, transparent);
  }
  .pill-text {
    line-height: 1;
  }

  .hover-card {
    position: fixed;
    z-index: 60;
    width: 300px;
    max-width: calc(100vw - 24px);
    padding: var(--space-6);
    background: var(--menu);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    box-shadow: var(--shadow-popover);
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    text-align: left;
  }
  .card-group {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }
  .card-heading {
    padding: var(--space-2) var(--space-8);
    font: var(--text-detail);
    color: var(--text3);
  }
  .card-sep {
    height: 1px;
    background: var(--line2);
    margin: var(--space-2) var(--space-4);
  }
  .card-row {
    display: flex;
    align-items: flex-start;
    gap: var(--space-8);
    width: 100%;
    padding: var(--space-6) var(--space-8);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--paper);
    text-align: left;
    cursor: pointer;
  }
  .card-row:hover {
    background: var(--smoke);
  }
  .card-row.earlier {
    opacity: 0.85;
  }
  .row-glyph {
    display: inline-flex;
    align-items: center;
    padding-top: var(--space-2);
    flex: none;
  }
  .row-glyph.open { color: var(--mint); }
  .row-glyph.draft { color: var(--text3); }
  .row-glyph.conflict { color: var(--amber); }
  .row-glyph.merged { color: var(--violet); }
  .row-glyph.closed { color: var(--coral); }
  .row-glyph.stack { color: var(--blue); }

  .row-body {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
    flex: 1;
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
  .row-title {
    font: var(--text-body);
    color: var(--paper);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .row-branches {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    font: var(--text-detail);
    color: var(--text3);
    min-width: 0;
  }
  .branch-name {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .arrow {
    flex: none;
    color: var(--text3);
  }
</style>
