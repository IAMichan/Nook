<script lang="ts" module>
  /** One source Nook looked in for an answer, as the Mac's `SourcesDisclosure` groups it. */
  export interface TranscriptSource {
    title: string;
    detail?: string;
    state: "running" | "found" | "empty" | "failed";
  }

  export interface TranscriptReference {
    number: number;
    title: string;
    url?: string;
  }

  /** A message as the surface shows it; Nook's answers carry where it looked and the plan it keeps. */
  export interface TranscriptMessage {
    id?: string;
    fromNook: boolean;
    text: string;
    streaming?: boolean;
    /** What Nook does right now ("Reading the page…"), while it answers. */
    status?: string;
    failed?: boolean;
    /** How Nook answered ("read on this Mac, only a filtered note went out"). */
    notice?: string;
    /** The answer holds something only Nook's own window can show (a plan to approve, a mail, a chart). */
    onMac?: boolean;
    sources?: { summary: string; running?: boolean; items: TranscriptSource[]; references?: TranscriptReference[] };
    tasks?: { text: string; status: "pending" | "active" | "done" | "cancelled" }[];
  }

  export interface TranscriptTexts {
    thinking: string;
    onMac: string;
    copy: string;
    copyTitle: string;
    copied: string;
  }
</script>

<script lang="ts">
  // A conversation with Nook as Nook's own window draws it: your questions in a bubble on the right, Nook's answers as
  // plain prose (Markdown) beside the edge, with the plan it keeps as a checklist, one quiet line for where it looked
  // that opens to the sources, and while it works a shimmering line of what it does. Colors come from the surface as
  // `--nt-*` variables. Every text from the model is escaped (`renderMarkdown`); links open in a new tab.
  import { renderMarkdown } from "./markdown";

  let { messages, texts }: { messages: readonly TranscriptMessage[]; texts: TranscriptTexts } = $props();

  // Which answers' sources are open, by message; an answer's line is closed until you open it, as on the Mac.
  let opened = $state<Record<string, boolean>>({});

  const markdownTexts = $derived({ copy: texts.copy, copyTitle: texts.copyTitle });

  function keyOf(message: TranscriptMessage, index: number) {
    return message.id || `${index}`;
  }

  function webHref(text: string | null | undefined) {
    try {
      const url = new URL(text || "");
      return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
    } catch {
      return null;
    }
  }

  async function click(e: MouseEvent) {
    const target = e.target as HTMLElement;
    const copy = target.closest<HTMLButtonElement>("[data-copy-code]");
    if (copy) {
      const code = copy.parentElement?.querySelector("code")?.textContent ?? "";
      await navigator.clipboard?.writeText(code).catch(() => {});
      const before = copy.textContent;
      copy.textContent = texts.copied;
      setTimeout(() => (copy.textContent = before), 1200);
      return;
    }
    const link = target.closest<HTMLAnchorElement>("a[href]");
    if (link) {
      e.preventDefault();
      const href = webHref(link.getAttribute("href"));
      if (href) window.open(href, "_blank", "noopener,noreferrer");
    }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="nook-transcript" onclick={click}>
  {#each messages as message, index (keyOf(message, index))}
    {#if !message.fromNook}
      <div class="you">{message.text}</div>
    {:else}
      {@const key = keyOf(message, index)}
      <div class="nook" class:failed={message.failed}>
        {#if message.tasks?.length}
          <ul class="tasks">
            {#each message.tasks as task, i (i)}
              <li class={task.status}>
                <span class="mark" aria-hidden="true">
                  {#if task.status === "done"}
                    <svg viewBox="0 0 16 16"><path d="m4 8.5 2.5 2.5 5.5-6" /></svg>
                  {:else if task.status === "active"}
                    <span class="spin"></span>
                  {/if}
                </span>
                <span>{task.text}</span>
              </li>
            {/each}
          </ul>
        {/if}
        {#if message.text}
          <div class="prose">{@html renderMarkdown(message.text, markdownTexts)}</div>
        {:else if message.streaming && !message.status}
          <span class="dots" aria-label={texts.thinking}><i></i><i></i><i></i></span>
        {/if}
        {#if message.streaming && message.status}
          <div class="status shimmer">{message.status}</div>
        {/if}
        {#if message.sources && (message.sources.items.length || message.sources.references?.length)}
          <div class="sources">
            <button
              type="button"
              class="sources-line"
              class:running={message.sources.running}
              aria-expanded={!!opened[key]}
              onclick={() => (opened[key] = !opened[key])}
            >
              <svg class="chev" class:open={opened[key]} viewBox="0 0 16 16" aria-hidden="true"><path d="m6 4 4 4-4 4" /></svg>
              <span class:shimmer={message.sources.running}>{message.sources.summary}</span>
              {#if message.sources.items.some((s) => s.state === "failed")}<span class="badge" aria-hidden="true">!</span>{/if}
            </button>
            {#if opened[key]}
              <ul class="source-list">
                {#each message.sources.items as source, i (i)}
                  <li class={"s-" + source.state}>
                    <span class="state" aria-hidden="true"></span>
                    <span class="source-title">{source.title}</span>
                    {#if source.detail}<span class="source-detail">{source.detail}</span>{/if}
                  </li>
                {/each}
                {#each message.sources.references ?? [] as reference (reference.number)}
                  <li class="reference">
                    <span class="number">{reference.number}</span>
                    {#if webHref(reference.url)}
                      <a href={webHref(reference.url)}>{reference.title}</a>
                    {:else}
                      <span class="source-title">{reference.title}</span>
                    {/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </div>
        {/if}
        {#if message.notice && !message.streaming}
          <div class="note">{message.notice}</div>
        {/if}
        {#if message.onMac}
          <div class="note on-mac">{texts.onMac}</div>
        {/if}
      </div>
    {/if}
  {/each}
</div>

<style>
  /* Every color comes from the surface (`--nt-*`); the fallbacks are Nook's own dark theme. */
  .nook-transcript { display: flex; flex-direction: column; gap: 18px; min-width: 0; color: var(--nt-text, #ececef); }
  .you {
    align-self: flex-end;
    max-width: 85%;
    padding: 8px 13px;
    border-radius: var(--nt-bubble-radius, 16px);
    background: var(--nt-bubble, #26262b);
    color: var(--nt-text, #ececef);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .nook { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  .failed .prose { color: var(--nt-error, #ff6b5e); }

  .prose { overflow-wrap: anywhere; line-height: 1.55; }
  .prose :global(p) { margin: 0 0 10px; }
  .prose :global(p:last-child), .prose :global(ul:last-child), .prose :global(ol:last-child) { margin-bottom: 0; }
  .prose :global(h3), .prose :global(h4), .prose :global(h5), .prose :global(h6) { margin: 14px 0 6px; font-size: 1em; font-weight: 600; }
  .prose :global(h3:first-child), .prose :global(h4:first-child) { margin-top: 0; }
  .prose :global(ul), .prose :global(ol) { margin: 0 0 10px; padding-left: 20px; }
  .prose :global(li) { margin: 3px 0; }
  .prose :global(li::marker) { color: var(--nt-faint, #8b8b94); }
  .prose :global(strong) { font-weight: 600; }
  .prose :global(a) { color: var(--nt-accent, #8ab4ff); text-decoration: none; }
  .prose :global(a:hover) { text-decoration: underline; }
  .prose :global(code) { font-family: var(--nt-mono, ui-monospace, "SF Mono", Menlo, monospace); font-size: 0.9em; padding: 1px 5px; border-radius: 5px; background: var(--nt-code, rgb(127 127 127 / 0.16)); }
  .prose :global(.code-block) { position: relative; margin: 0 0 10px; }
  .prose :global(pre) { margin: 0; padding: 10px 12px; overflow-x: auto; border-radius: var(--nt-card-radius, 10px); border: 1px solid var(--nt-line, #2c2c31); background: var(--nt-card, #17171a); }
  .prose :global(pre code) { padding: 0; background: none; font-size: 12px; line-height: 1.5; }
  .prose :global(.copy-code) {
    position: absolute;
    top: 6px;
    right: 6px;
    padding: 2px 8px;
    border: 1px solid var(--nt-line, #2c2c31);
    border-radius: 6px;
    background: var(--nt-card, #17171a);
    color: var(--nt-faint, #8b8b94);
    font: inherit;
    font-size: 11px;
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.15s ease;
  }
  .prose :global(.code-block:hover .copy-code), .prose :global(.copy-code:focus-visible) { opacity: 1; }
  .prose :global(blockquote) { margin: 0 0 10px; padding-left: 10px; border-left: 2px solid var(--nt-line, #2c2c31); color: var(--nt-faint, #8b8b94); }
  .prose :global(table) { border-collapse: collapse; margin: 0 0 10px; font-size: 12px; display: block; overflow-x: auto; }
  .prose :global(th), .prose :global(td) { padding: 4px 8px; border: 1px solid var(--nt-line, #2c2c31); text-align: left; }
  .prose :global(th) { font-weight: 600; }
  .prose :global(.cite) { font-size: 0.7em; padding: 0 4px; margin-left: 1px; border-radius: 4px; background: var(--nt-code, rgb(127 127 127 / 0.16)); color: var(--nt-faint, #8b8b94); }

  .status { font-size: 12px; color: var(--nt-faint, #8b8b94); }
  .shimmer {
    background: linear-gradient(90deg, var(--nt-faint, #8b8b94) 0%, var(--nt-text, #ececef) 50%, var(--nt-faint, #8b8b94) 100%);
    background-size: 200% 100%;
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    animation: shimmer 1.8s linear infinite;
  }
  @keyframes shimmer { from { background-position: 100% 0; } to { background-position: -100% 0; } }

  .dots { display: inline-flex; gap: 4px; padding: 6px 0; }
  .dots i { width: 6px; height: 6px; border-radius: 50%; background: var(--nt-faint, #8b8b94); animation: blink 1.2s infinite ease-in-out; }
  .dots i:nth-child(2) { animation-delay: 0.15s; }
  .dots i:nth-child(3) { animation-delay: 0.3s; }
  @keyframes blink { 0%, 80%, 100% { opacity: 0.25; } 40% { opacity: 1; } }

  .tasks { list-style: none; margin: 0; padding: 8px 10px; display: flex; flex-direction: column; gap: 5px; border: 1px solid var(--nt-line, #2c2c31); border-radius: var(--nt-card-radius, 10px); background: var(--nt-card, #17171a); font-size: 12px; }
  .tasks li { display: flex; align-items: flex-start; gap: 8px; }
  .tasks .mark { flex-shrink: 0; display: grid; place-items: center; width: 14px; height: 14px; margin-top: 2px; border: 1.5px solid var(--nt-faint, #8b8b94); border-radius: 50%; box-sizing: border-box; }
  .tasks .done .mark { border-color: var(--nt-accent, #8ab4ff); background: var(--nt-accent, #8ab4ff); }
  .tasks .done .mark svg { width: 10px; height: 10px; fill: none; stroke: var(--nt-on-accent, #0b0b0c); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }
  .tasks .done, .tasks .cancelled { color: var(--nt-faint, #8b8b94); }
  .tasks .cancelled span:last-child { text-decoration: line-through; }
  .tasks .active .mark { border-color: var(--nt-accent, #8ab4ff); }
  .tasks .spin { width: 6px; height: 6px; border-radius: 50%; background: var(--nt-accent, #8ab4ff); animation: blink 1.2s infinite ease-in-out; }

  .sources { display: flex; flex-direction: column; gap: 6px; }
  .sources-line {
    align-self: flex-start;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    margin: 0 0 0 -6px;
    padding: 3px 8px 3px 4px;
    border: 0;
    border-radius: 999px;
    background: transparent;
    color: var(--nt-faint, #8b8b94);
    font: inherit;
    font-size: 12px;
    cursor: pointer;
  }
  .sources-line:hover { background: var(--nt-hover, rgb(127 127 127 / 0.12)); color: var(--nt-text, #ececef); }
  .chev { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; transition: transform 0.15s ease; }
  .chev.open { transform: rotate(90deg); }
  .badge { display: grid; place-items: center; width: 14px; height: 14px; border-radius: 50%; background: var(--nt-warn, #e0a23a); color: #000; font-size: 10px; font-weight: 700; }
  .source-list { list-style: none; margin: 0; padding: 8px 10px; display: flex; flex-direction: column; gap: 6px; border: 1px solid var(--nt-line, #2c2c31); border-radius: var(--nt-card-radius, 10px); background: var(--nt-card, #17171a); font-size: 12px; }
  .source-list li { display: flex; align-items: baseline; gap: 6px; min-width: 0; flex-wrap: wrap; }
  .state { flex-shrink: 0; width: 6px; height: 6px; border-radius: 50%; background: var(--nt-ok, #3ecf8e); transform: translateY(-1px); }
  .s-empty .state { background: var(--nt-faint, #8b8b94); }
  .s-failed .state { background: var(--nt-error, #ff6b5e); }
  .s-running .state { background: var(--nt-accent, #8ab4ff); animation: blink 1.2s infinite ease-in-out; }
  .source-title { font-weight: 500; }
  .source-detail { color: var(--nt-faint, #8b8b94); overflow-wrap: anywhere; }
  .s-failed .source-detail { color: var(--nt-error, #ff6b5e); }
  .reference .number { flex-shrink: 0; min-width: 16px; padding: 0 4px; border-radius: 4px; background: var(--nt-code, rgb(127 127 127 / 0.16)); color: var(--nt-faint, #8b8b94); font-size: 10px; text-align: center; }
  .reference a { color: var(--nt-accent, #8ab4ff); text-decoration: none; overflow-wrap: anywhere; }
  .reference a:hover { text-decoration: underline; }

  .note { font-size: 12px; color: var(--nt-faint, #8b8b94); }
  @media (prefers-reduced-motion: reduce) {
    .shimmer, .dots i, .spin, .s-running .state { animation: none; }
    .shimmer { color: var(--nt-faint, #8b8b94); background: none; }
  }
</style>
