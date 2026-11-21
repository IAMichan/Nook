<script lang="ts">
  // Context window pill and breakdown popover (`SessionUsageSection`, `ContextUsageBar`, `ContextUsageBreakdown`,
  // `ContextMeter` on macOS — AG-65 & AG-66): amber warning near auto-compact threshold, live "Compacting…" indicator,
  // per-part token breakdown with auto-compact threshold mark, and a quick `Compact now` (`/compact`) button.
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import {
    isActive,
    workspaceApi,
    type ContextLevel,
    type ContextPart,
    type ContextUsage,
    type RunEvent,
    type WorkspaceRun,
  } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";

  let {
    run,
    events = [],
    below = false,
    canCompact = false,
  }: {
    run: WorkspaceRun;
    events?: RunEvent[];
    below?: boolean;
    canCompact?: boolean;
  } = $props();

  const DEFAULT_AUTO_COMPACT_TOKENS = 350_000;
  const AUTO_COMPACT_WINDOW_SHARE = 0.8;
  const BASE_SYSTEM_PROMPT_TOKENS = 2_500;

  let fetched = $state<ContextUsage | null>(null);
  let open = $state(false);
  let sendingCompact = $state(false);

  function approxTokens(text?: string | null): number {
    if (!text) return 0;
    return Math.ceil(text.length / 4);
  }

  function hasRunningCompaction(list: RunEvent[]): boolean {
    for (let i = list.length - 1; i >= 0; i--) {
      const e = list[i];
      if (e.kind === "system" && e.tool === "compaction" && e.state === "running") return true;
      if (e.kind === "user") return false;
    }
    return false;
  }

  function levelFromPressure(p: number): ContextLevel {
    return p > 0.9 ? "critical" : p > 0.8 ? "warning" : "normal";
  }

  /** Local mirror of `nook_core::workspace::context_usage::compute`, used immediately and as fallback. */
  function estimateUsage(r: WorkspaceRun, list: RunEvent[]): ContextUsage | null {
    const compacting = Boolean(r.compacting) || hasRunningCompaction(list);
    const windowTokens = r.usage.contextWindow ?? 0;
    const usedRaw = r.usage.contextTokens ?? 0;
    if (windowTokens <= 0 || (usedRaw <= 0 && !compacting)) return null;

    const used = Math.min(usedRaw, windowTokens);
    const autoCompactAt = Math.min(DEFAULT_AUTO_COMPACT_TOKENS, Math.floor(windowTokens * AUTO_COMPACT_WINDOW_SHARE));
    const fraction = Math.min(1, used / windowTokens);
    const budget = autoCompactAt > 0 ? Math.min(autoCompactAt, windowTokens) : windowTokens;
    const pressure = budget > 0 ? Math.min(1, used / budget) : 0;
    const level = levelFromPressure(pressure);

    let start = 0;
    for (let i = list.length - 1; i >= 0; i--) {
      const e = list[i];
      if (
        e.kind === "system" &&
        (e.tool === "clear" || (e.tool === "compaction" && e.state === "done"))
      ) {
        start = i + 1;
        break;
      }
    }

    let rawMessages = 0;
    let rawTools = 0;
    for (let i = start; i < list.length; i++) {
      const e = list[i];
      if (e.rolledBack) continue;
      if (e.kind === "user" || e.kind === "assistant" || e.kind === "thinking") {
        rawMessages += approxTokens(e.text);
      } else if (e.kind === "tool" || e.kind === "fileChange") {
        rawTools += approxTokens(e.text) + approxTokens(e.detail) + approxTokens(e.output);
      }
    }

    const rawSystem =
      used > 0
        ? Math.min(BASE_SYSTEM_PROMPT_TOKENS, Math.floor(used / 4)) + approxTokens(r.instructions)
        : 0;

    const parts: ContextPart[] = [];
    const push = (id: string, tokens: number, kind: ContextPart["kind"]) => {
      if (tokens > 0) parts.push({ id, tokens, share: tokens / windowTokens, kind });
    };

    if (used > 0) {
      const contentTotal = rawMessages + rawTools;
      if (contentTotal === 0) {
        if (rawSystem > 0 && rawSystem < used) {
          push("system_prompt", rawSystem, "used");
          push("conversation", used - rawSystem, "used");
        } else {
          push("conversation", used, "used");
        }
      } else {
        const systemTokens = Math.min(rawSystem, Math.floor(used / 3));
        const remaining = Math.max(0, used - systemTokens);
        const msgTokens = Math.floor((remaining * rawMessages) / contentTotal);
        const toolTokens = Math.max(0, remaining - msgTokens);
        push("system_prompt", systemTokens, "used");
        push("messages", msgTokens, "used");
        push("system_tools", toolTokens, "used");
      }
    }

    const buffer = Math.max(0, windowTokens - Math.max(autoCompactAt, used));
    const free = Math.max(0, windowTokens - used - buffer);
    push("autocompact_buffer", buffer, "buffer");
    push("free_space", free, "free");

    return {
      usedTokens: used,
      window: windowTokens,
      fraction,
      pressure,
      level,
      autoCompactAt,
      headroomTokens: Math.max(0, autoCompactAt - used),
      compacting,
      detailed: false,
      parts,
    };
  }

  const localUsage = $derived(estimateUsage(run, events));
  // Prefer backend calculation while open (when available and matching the current run/tokens), else local estimate.
  const usage = $derived.by(() => {
    if (!localUsage) return fetched;
    if (
      fetched &&
      fetched.window === localUsage.window &&
      fetched.usedTokens === localUsage.usedTokens &&
      fetched.compacting === localUsage.compacting
    ) {
      return fetched;
    }
    return localUsage;
  });

  const active = $derived(isActive(run.status));
  const compacting = $derived(Boolean(run.compacting) || Boolean(usage?.compacting) || hasRunningCompaction(events));

  async function refreshBreakdown() {
    try {
      const res = await workspaceApi.contextUsage(run.id);
      if (res) fetched = res;
    } catch {
      // Command may not be registered yet; local estimate stays active.
    }
  }

  $effect(() => {
    void run.id;
    fetched = null;
  });

  function formatTokens(n: number): string {
    if (n >= 1_000_000) {
      const m = n / 1_000_000;
      return `${Number.isInteger(m) ? m : m.toFixed(1)}m`;
    }
    if (n >= 1_000) return `${Math.round(n / 1_000)}k`;
    return `${n}`;
  }

  function formatPercent(f: number): string {
    const pct = Math.min(Math.max(f, 0), 1) * 100;
    if (pct > 0 && pct < 10) return `${pct.toFixed(1)}%`;
    return `${Math.round(pct)}%`;
  }

  function partLabel(id: string): string {
    switch (id) {
      case "system_prompt": return tr("Systeemprompt", "System prompt");
      case "messages": return tr("Berichten", "Messages");
      case "system_tools": return tr("Tool-aanroepen", "Tool calls");
      case "conversation": return tr("Gesprek", "Conversation");
      case "autocompact_buffer": return tr("Buffer voor samenvatten", "Autocompact buffer");
      case "free_space": return tr("Vrije ruimte", "Free space");
      default: return id;
    }
  }

  function partClass(p: ContextPart): string {
    if (p.kind === "buffer") return "part-buffer";
    if (p.kind === "free") return "part-free";
    switch (p.id) {
      case "messages":
      case "conversation": return "part-messages";
      case "system_tools": return "part-tools";
      case "system_prompt": return "part-system";
      default: return "part-other";
    }
  }

  async function compactNow(close: () => void) {
    if (sendingCompact || active || compacting) return;
    sendingCompact = true;
    close();
    try {
      await workspace.act(() => workspaceApi.send(run.id, "/compact"));
    } finally {
      sendingCompact = false;
    }
  }

  // Ring geometry for the compact trigger pill (12x12 SVG).
  const RING_R = 4.5;
  const RING_C = 2 * Math.PI * RING_R;
</script>

{#if compacting && !usage}
  <span
    class="pill compacting"
    title={tr("Vat het gesprek samen…", "Compacting the conversation…")}
  >
    <span class="spin"><Ico name="loader-circle" size={12} stroke={2.4} /></span>
    <span>{tr("Samenvatten…", "Compacting…")}</span>
  </span>
{:else if usage}
  {@const thresholdPct = usage.autoCompactAt && usage.autoCompactAt < usage.window ? (usage.autoCompactAt / usage.window) * 100 : null}
  <Dropdown
    width={300}
    align="right"
    {below}
    bind:open
    onopen={refreshBreakdown}
    label={tr("Context", "Context")}
  >
    {#snippet trigger({ toggle, open: isOpen })}
      <button
        type="button"
        class="pill {compacting ? 'compacting' : usage.level}"
        class:lit={isOpen}
        aria-expanded={isOpen}
        title={compacting
          ? tr("Vat het gesprek samen…", "Compacting the conversation…")
          : tr("Contextvenster {pct} · {used}/{window}", "Context window {pct} · {used}/{window}", {
              pct: formatPercent(usage.fraction),
              used: formatTokens(usage.usedTokens),
              window: formatTokens(usage.window),
            })}
        onclick={toggle}
      >
        {#if compacting}
          <span class="spin"><Ico name="loader-circle" size={12} stroke={2.4} /></span>
          <span>{tr("Samenvatten…", "Compacting…")}</span>
        {:else}
          <svg class="ring" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
            <circle class="ring-track" cx="6" cy="6" r={RING_R} />
            <circle
              class="ring-fill"
              cx="6"
              cy="6"
              r={RING_R}
              stroke-dasharray={RING_C}
              stroke-dashoffset={RING_C * (1 - Math.min(1, Math.max(0, usage.fraction)))}
            />
          </svg>
          <span class="mono">ctx {formatPercent(usage.fraction)}</span>
        {/if}
      </button>
    {/snippet}

    {#snippet children({ close })}
      <div class="card">
        <div class="head">
          <span class="heading">{tr("Context", "Context")}</span>
          <span class="nums">
            <strong class="pct {usage.level}">{formatPercent(usage.fraction)}</strong>
            <span class="tokens">{formatTokens(usage.usedTokens)} / {formatTokens(usage.window)}</span>
          </span>
        </div>

        <div class="bar-wrap" aria-hidden="true">
          <div class="bar">
            {#each usage.parts.filter((p) => p.kind !== "free") as part (part.id)}
              <span class="seg {partClass(part)}" style:width="{Math.max(0.5, part.share * 100)}%"></span>
            {/each}
          </div>
          {#if thresholdPct !== null && usage.autoCompactAt}
            <span
              class="threshold-mark"
              style:left="{thresholdPct}%"
              title={tr("Automatisch samenvatten bij {tokens}", "Auto-compact at {tokens}", { tokens: formatTokens(usage.autoCompactAt) })}
            ></span>
          {/if}
        </div>

        {#if compacting}
          <div class="notice warning">
            <span class="spin"><Ico name="loader-circle" size={12} stroke={2.4} /></span>
            <span>{tr("Vat het gesprek samen…", "Compacting the conversation…")}</span>
          </div>
        {:else if usage.level !== "normal"}
          <div class="notice {usage.level}">
            <Ico name="triangle-alert" size={12} stroke={2.2} />
            <span>{tr("Dit gesprek wordt lang: /compact vat het samen voordat het vanzelf gebeurt.", "This conversation is getting long: /compact summarizes it before it happens by itself.")}</span>
          </div>
        {:else if usage.autoCompactAt}
          <p class="note">
            {tr("Vat automatisch samen bij ongeveer {tokens} tokens.", "Compacts automatically at about {tokens} tokens.", {
              tokens: formatTokens(usage.autoCompactAt),
            })}
          </p>
        {/if}

        <div class="parts">
          {#each usage.parts as part (part.id)}
            <div class="part-row" class:muted={part.kind !== "used"}>
              <span class="dot {partClass(part)}"></span>
              <span class="part-name">{partLabel(part.id)}</span>
              <span class="part-tokens">{formatTokens(part.tokens)}</span>
              <span class="part-share">{formatPercent(part.share)}</span>
            </div>
          {/each}
        </div>

        {#if usage.autoCompactAt}
          <div class="meta-row">
            <span>{tr("Ruimte tot automatisch samenvatten", "Headroom before auto-compact")}</span>
            <span class="mono">{formatTokens(usage.headroomTokens)}</span>
          </div>
        {/if}

        {#if !usage.detailed}
          <p class="footnote">{tr("Geschat op basis van het gebruik en de tijdlijn van deze sessie.", "Estimated from the session's usage and timeline.")}</p>
        {/if}

        {#if canCompact && !active && !compacting}
          <button type="button" class="compact-btn" disabled={sendingCompact} onclick={() => compactNow(close)}>
            <span>{tr("Nu samenvatten", "Compact now")}</span>
            <span class="cmd">/compact</span>
          </button>
        {/if}
      </div>
    {/snippet}
  </Dropdown>
{/if}

<style>
  .pill {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 24px;
    padding: 0 var(--space-6);
    margin: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    font: var(--text-caption);
    color: var(--text3);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    cursor: pointer;
  }
  .pill:hover,
  .pill.lit {
    background: var(--smoke);
    color: var(--paper);
  }
  .pill.warning,
  .pill.compacting {
    color: var(--amber);
  }
  .pill.critical {
    color: var(--coral);
  }
  .pill.compacting {
    cursor: default;
  }
  .mono {
    font-family: var(--mono);
  }
  .ring {
    transform: rotate(-90deg);
    flex: none;
  }
  .ring-track {
    fill: none;
    stroke: var(--line2);
    stroke-width: 1.75;
  }
  .ring-fill {
    fill: none;
    stroke: currentColor;
    stroke-width: 1.75;
    stroke-linecap: round;
  }
  .spin {
    display: inline-flex;
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .card {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    padding: var(--space-8);
  }
  .head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-8);
  }
  .heading {
    font: var(--text-label);
    color: var(--text3);
  }
  .nums {
    display: inline-flex;
    align-items: baseline;
    gap: var(--space-6);
    font-variant-numeric: tabular-nums;
  }
  .pct {
    font: var(--text-detail);
    font-weight: 600;
    color: var(--text-strong);
  }
  .pct.warning {
    color: var(--amber);
  }
  .pct.critical {
    color: var(--coral);
  }
  .tokens {
    font: var(--text-caption);
    font-family: var(--mono);
    color: var(--text3);
  }

  .bar-wrap {
    position: relative;
    padding: var(--space-2) 0;
  }
  .bar {
    display: flex;
    gap: 1px;
    height: 8px;
    border-radius: 999px;
    background: var(--line2);
    overflow: hidden;
  }
  .seg {
    display: block;
    height: 100%;
    flex: none;
  }
  .threshold-mark {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 2px;
    border-radius: 999px;
    background: var(--amber);
    transform: translateX(-1px);
  }

  .part-messages {
    background: var(--blue);
  }
  .part-tools {
    background: var(--mint);
  }
  .part-system {
    background: var(--violet);
  }
  .part-other {
    background: var(--text3);
  }
  .part-buffer {
    background: color-mix(in srgb, var(--text3) 45%, transparent);
  }
  .part-free {
    background: var(--line2);
  }

  .notice {
    display: flex;
    align-items: flex-start;
    gap: var(--space-6);
    padding: var(--space-6) var(--space-8);
    border-radius: var(--radius-control);
    border: 1px solid var(--line2);
    background: var(--surface);
    font: var(--text-detail);
    color: var(--paper);
  }
  .notice.warning {
    border-color: color-mix(in srgb, var(--amber) 40%, var(--line2));
    color: var(--amber);
  }
  .notice.critical {
    border-color: color-mix(in srgb, var(--coral) 45%, var(--line2));
    color: var(--coral);
  }
  .note {
    margin: 0;
    font: var(--text-detail);
    color: var(--text3);
  }

  .parts {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .part-row {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-detail);
    color: var(--paper);
    font-variant-numeric: tabular-nums;
  }
  .part-row.muted {
    color: var(--text2);
  }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex: none;
  }
  .part-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .part-tokens {
    color: var(--text2);
    font-family: var(--mono);
  }
  .part-share {
    width: 42px;
    text-align: right;
    color: var(--text3);
    font-family: var(--mono);
  }

  .meta-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-8);
    padding-top: var(--space-6);
    border-top: 1px solid var(--separator);
    font: var(--text-detail);
    color: var(--text2);
    font-variant-numeric: tabular-nums;
  }
  .footnote {
    margin: 0;
    font: var(--text-caption);
    color: var(--text3);
  }

  .compact-btn {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-8);
    width: 100%;
    height: 28px;
    padding: 0 var(--space-12);
    margin: 0;
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    background: transparent;
    font: var(--text-detail);
    font-weight: 500;
    color: var(--paper);
    cursor: pointer;
  }
  .compact-btn:hover:not(:disabled) {
    background: var(--smoke);
  }
  .compact-btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .cmd {
    font: var(--text-caption);
    font-family: var(--mono);
    color: var(--text3);
  }
</style>
