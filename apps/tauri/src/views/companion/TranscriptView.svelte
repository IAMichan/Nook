<script lang="ts">
  // A session's conversation as the iPhone reads it (`TranscriptConversation`): your messages in a soft bubble on the
  // right, the agent's answers as text, its work as quiet lines that open, a finished turn folded into "Worked for …".
  import { messageTime, type TimelineEntry } from "../../lib/companion";
  import { renderMarkdown } from "../../lib/markdown";
  import { richContent } from "../../lib/rich";
  import { duration, stepIcon, stepParts, tally, transcriptRows, type TranscriptRow } from "../../lib/transcript";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./ui/Ico.svelte";

  let { entries, working, onreply, onwhole }: { entries: TimelineEntry[]; working: boolean; onreply?: (text: string) => void; onwhole?: (entry: TimelineEntry) => void } = $props();
  const rows = $derived(transcriptRows(entries, working));
  let opened = $state<Record<string, boolean>>({});
  let longOpen = $state<Record<string, boolean>>({});
  let now = $state(Date.now() / 1000);
  $effect(() => {
    if (!working) return;
    const timer = setInterval(() => (now = Date.now() / 1000), 1000);
    return () => clearInterval(timer);
  });
  const isLong = (t: string) => t.length > 600 || t.split("\n").length > 8;
  async function copy(text: string) {
    try { await navigator.clipboard.writeText(text); } catch { /* nothing to copy to */ }
  }
</script>

{#snippet row(r: TranscriptRow)}
  {#if r.kind === "user"}
    <div class="user">
      <div class="bubble" class:folded={isLong(r.entry.text) && !longOpen[r.id]}>{r.entry.text}</div>
      {#if r.entry.clipped && onwhole}<button class="clipped" onclick={() => onwhole?.(r.entry)}><Ico name="list-plus" size={13} />{tr("Lees het hele bericht", "Read the whole message")}</button>{/if}
      {#if isLong(r.entry.text)}<button class="toggle" onclick={() => (longOpen[r.id] = !longOpen[r.id])}>{longOpen[r.id] ? tr("Toon minder", "Show less") : tr("Toon alles", "Show all")}</button>{/if}
      <span class="time">{messageTime(r.entry.date)}</span>
    </div>
  {:else if r.kind === "answer"}
    <div class="answer" class:final={r.final} class:failed={r.entry.failed}>
      <div class="markdown" use:richContent={r.entry.text}>{@html renderMarkdown(r.entry.text)}</div>
      {#if r.entry.clipped}{#if onwhole}<button class="clipped" onclick={() => onwhole?.(r.entry)}><Ico name="list-plus" size={13} />{tr("Lees het hele bericht", "Read the whole message")}</button>{:else}<span class="clipped"><Ico name="list-plus" size={13} />{tr("Lees het hele bericht", "Read the whole message")}</span>{/if}{/if}
      {#if r.final}
        <span class="foot"><span class="time">{messageTime(r.entry.date)}</span>
          <button class="copy" aria-label={tr("Kopieer", "Copy")} onclick={() => copy(r.entry.text)}><Ico name="copy" size={12} /></button>
          {#if onreply}<button class="copy" aria-label={tr("Beantwoord", "Reply")} onclick={() => onreply?.(r.entry.text)}><Ico name="reply" size={12} /></button>{/if}
        </span>
      {/if}
    </div>
  {:else if r.kind === "work"}
    {#if r.steps.length === 1}
      {@render step(r.steps[0], false)}
    {:else}
      {@const t = tally(r.steps)}
      <button class="work" onclick={() => (opened[r.id] = !opened[r.id])}>
        <span class="wicon">{#if t.failed}<span style:color="rgba(255,100,103,.6)"><Ico name="circle-alert" size={15} /></span>{:else}<Ico name={t.icon} size={15} />{/if}</span>
        <span class="wtext">{t.sentence}</span>
        <span class="chev" class:open={opened[r.id]}><Ico name="chevron-right" size={10} stroke={3} /></span>
      </button>
      {#if opened[r.id]}<div class="steps">{#each r.steps as s (s.id)}{@render step(s, false)}{/each}</div>{/if}
    {/if}
  {:else if r.kind === "notice"}
    {#if r.entry.kind === "error"}
      <div class="error"><span><Ico name="octagon-alert" size={16} fill="currentColor" stroke={0} /></span><span class="etext">{r.entry.text}</span></div>
    {:else if r.entry.detail === "compacted"}
      <div class="compact"><Ico name="minimize-2" size={12} />{tr("Context samengevat", "Context compacted")}</div>
    {:else}
      <div class="work static"><span class="wicon"><Ico name="info" size={15} /></span><span class="wtext">{r.entry.text}</span></div>
    {/if}
  {:else if r.kind === "fold"}
    <button class="fold" onclick={() => (opened[r.id] = !opened[r.id])}>
      <span>{r.seconds ? tr("{d} gewerkt", "Worked for {d}", { d: duration(r.seconds) }) : tr("Gewerkt", "Worked")}</span>
      <span class="chev" class:open={opened[r.id]}><Ico name="chevron-right" size={10} stroke={3} /></span>
    </button>
    {#if opened[r.id]}<div class="folded">{#each r.rows as inner (inner.id)}{@render row(inner)}{/each}</div>{/if}
  {:else if r.kind === "working"}
    <div class="fold static">{r.since ? tr("Werkt al {d}", "Working for {d}", { d: duration(Math.max(0, now - r.since)) }) : tr("Aan het werk", "Working")}</div>
  {:else if r.kind === "live"}
    {#if r.entry}{@render step(r.entry, true)}
    {:else}<div class="work static breathe"><span class="wicon"><Ico name="brain" size={15} /></span><span class="wtext">{tr("Aan het denken…", "Thinking…")}</span></div>{/if}
  {/if}
{/snippet}

{#snippet step(s: TimelineEntry, live: boolean)}
  {@const p = stepParts(s)}
  <button class="work" class:breathe={live} onclick={() => s.output && (opened[s.id] = !opened[s.id])}>
    <span class="wicon">{#if s.failed}<span style:color="rgba(255,100,103,.6)"><Ico name="circle-alert" size={15} /></span>{:else}<Ico name={stepIcon(s)} size={15} />{/if}</span>
    <span class="wtext">{p.verb}{#if p.detail}{" "}<span class:mono={p.mono}>{p.detail}</span>{/if}</span>
    {#if s.output}<span class="chev" class:open={opened[s.id]}><Ico name="chevron-right" size={10} stroke={3} /></span>{/if}
    {#if s.failed}<span style:color="rgba(255,100,103,.6)"><Ico name="x" size={12} stroke={3} /></span>{/if}
  </button>
  {#if s.output && opened[s.id]}
    <pre class="output" class:failed={s.failed}>{#each s.output.split("\n") as line, i (i)}<span class:add={line.startsWith("+")} class:del={line.startsWith("-")} class:hunk={line.startsWith("@@")}>{line}</span>{"\n"}{/each}</pre>
  {/if}
{/snippet}

<div class="transcript">
  {#each rows as r (r.id)}{@render row(r)}{/each}
</div>

<style>
  .transcript { display: flex; flex-direction: column; gap: 12px; }
  .user { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; padding: 18px 0 2px 56px; }
  .bubble { background: var(--bubble); border-radius: 16px; padding: 12px; font: var(--pt-body); line-height: 1.55; color: var(--paper); white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; }
  .bubble.folded { max-height: 176px; overflow: hidden; -webkit-mask-image: linear-gradient(#000 calc(100% - 28px), transparent); mask-image: linear-gradient(#000 calc(100% - 28px), transparent); }
  .toggle { font: var(--pt-label) !important; color: var(--text2) !important; }
  .time { font: var(--pt-caption); color: var(--text3); }
  .answer { padding: 0 2px 2px; color: var(--text-strong); font: var(--pt-body); overflow-wrap: anywhere; display: flex; flex-direction: column; gap: 4px; }
  .answer.final { padding-bottom: 12px; }
  .answer.failed { color: var(--coral); }
  .answer :global(.markdown a) { color: var(--blue); }
  .answer :global(.markdown pre) { background: var(--well); border: 0.5px solid var(--hairline); border-radius: 10px; }
  .clipped { font: var(--pt-label) !important; color: var(--blue) !important; display: flex; align-items: center; gap: 6px; font: var(--pt-label); color: var(--blue); }
  .foot { display: flex; align-items: center; gap: 4px; }
  .copy { width: 28px; height: 28px; display: inline-flex; align-items: center; justify-content: center; color: var(--text3) !important; }
  .work { display: flex; align-items: center; gap: 6px; min-height: 26px; width: 100%; text-align: left; font: var(--pt-body) !important; color: var(--text3) !important; }
  .wicon { width: 24px; display: inline-flex; justify-content: center; flex: none; }
  .wtext { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .mono { font: var(--pt-code); font-size: 14px; }
  .chev { display: inline-flex; opacity: 0.7; transition: transform var(--reveal); }
  .chev.open { transform: rotate(90deg); }
  .steps { display: flex; flex-direction: column; gap: 2px; }
  .output { margin: 0 0 0 30px; padding: 8px; max-height: 240px; overflow: auto; background: var(--well); border: 0.5px solid var(--hairline); border-radius: 8px; font: var(--pt-code); font-size: 13px; color: var(--text2); white-space: pre; user-select: text; }
  .output.failed { border-color: rgba(255, 100, 103, 0.35); }
  .add { color: var(--mint); }
  .del { color: var(--coral); }
  .hunk { color: var(--text3); }
  .fold { display: flex; align-items: center; gap: 6px; width: 100%; padding: 2px 0 8px; border-bottom: 1px solid var(--hairline) !important; font: var(--pt-body) !important; color: var(--text3) !important; text-align: left; }
  .folded { display: flex; flex-direction: column; gap: 12px; }
  .compact { align-self: center; display: flex; align-items: center; gap: 6px; padding: 8px 0; font: var(--pt-caption); color: var(--text3); }
  .error { display: flex; gap: 8px; padding: 12px; margin: 4px 0; background: var(--surface); border-radius: 10px; color: var(--coral); }
  .etext { font: var(--pt-body); white-space: pre-wrap; user-select: text; }
</style>
