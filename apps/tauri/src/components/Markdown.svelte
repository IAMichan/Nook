<script lang="ts">
  // Rich Markdown view (`MarkdownView` & `MarkdownDetailsBlock` on the Mac): headings, paragraphs, nested/task
  // lists, syntax-colored code blocks with fence filenames / wrap / run / sandboxed HTML+SVG preview, `<details>`,
  // standalone images, tables with Markdown/CSV copy, callouts, and link addresses on hover.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { tr } from "../lib/i18n.svelte";
  import {
    parseMarkdownBlocks,
    renderInlineMarkdown,
    type Callout,
    type InlineOptions,
  } from "../lib/markdown-blocks";
  import { hasRich, renderKatex, renderMermaid, splitMath } from "../lib/rich";
  import { nook } from "../lib/state.svelte";
  import Icon from "./Icon.svelte";
  import Markdown from "./Markdown.svelte";
  import MarkdownCode from "./MarkdownCode.svelte";
  import MarkdownImage from "./MarkdownImage.svelte";
  import MarkdownTable from "./MarkdownTable.svelte";

  let {
    text,
    baseFolder = null,
    onrun,
    citation,
  }: {
    text: string;
    baseFolder?: string | null;
    onrun?: (command: string, title: string | null) => void;
    citation?: InlineOptions["citation"];
  } = $props();

  const blocks = $derived(parseMarkdownBlocks(text));
  const inlineOpts = $derived<InlineOptions>(citation ? { citation } : {});

  // Keep `<details>` open state per block index while an answer streams.
  let openDetails = $state<Record<number, boolean>>({});
  let diagrams = $state<Record<number, string>>({});
  let mathHtml = $state<Record<number, string>>({});
  // Settings › Appearance › Text and layout › Render math (`renderMath` on the Mac): off, math stays its source.
  const mathOn = $derived(nook.settings?.renderMath !== false);

  function toggleDetails(index: number) {
    openDetails = { ...openDetails, [index]: !openDetails[index] };
  }

  // Render Mermaid and display math blocks cleanly into keyed maps.
  $effect(() => {
    const currentBlocks = blocks;
    let cancelled = false;
    currentBlocks.forEach((block, index) => {
      if (block.kind === "mermaid") {
        void renderMermaid(block.code).then((svg) => {
          if (!cancelled && svg) diagrams = { ...diagrams, [index]: svg };
        });
      } else if (block.kind === "math" && mathOn) {
        void renderKatex(block.tex, true).then((html) => {
          if (!cancelled && html) mathHtml = { ...mathHtml, [index]: html };
        });
      }
    });
    return () => {
      cancelled = true;
    };
  });

  // Typeset inline `$...$` math inside paragraphs/lists/quotes when present.
  let rootEl: HTMLDivElement;
  $effect(() => {
    const source = text;
    if (!rootEl || !mathOn || !hasRich(source)) return;
    let cancelled = false;
    const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.parentElement?.closest("code, pre, .katex, .diagram, .math-block") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const nodes: Text[] = [];
    while (walker.nextNode()) nodes.push(walker.currentNode as Text);
    const hasInlineMath = nodes.some((n) => splitMath(n.data).some((p) => "math" in p));
    if (!hasInlineMath) return;
    void (async () => {
      for (const node of nodes) {
        if (cancelled || !node.isConnected) return;
        const parts = splitMath(node.data);
        if (parts.length < 2 && !("math" in (parts[0] ?? { text: "" }))) continue;
        const fragment = document.createDocumentFragment();
        for (const part of parts) {
          if ("text" in part) {
            fragment.append(part.text);
          } else {
            const span = document.createElement(part.display ? "div" : "span");
            span.innerHTML = await renderKatex(part.math, part.display);
            if (cancelled || !node.isConnected) return;
            fragment.append(span);
          }
        }
        node.replaceWith(fragment);
      }
    })();
    return () => {
      cancelled = true;
    };
  });

  function renderInline(src: string): string {
    return renderInlineMarkdown(src, inlineOpts);
  }

  function calloutIcon(kind: Callout["kind"]): "alert" | "sparkle" | "brain" {
    switch (kind) {
      case "tip":
        return "sparkle";
      case "warning":
      case "danger":
        return "alert";
      default:
        return "brain";
    }
  }

  function handleClick(e: MouseEvent) {
    const a = (e.target as HTMLElement).closest("a[data-external]") as HTMLAnchorElement | null;
    if (a) {
      e.preventDefault();
      openUrl(a.href);
    }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="markdown" bind:this={rootEl} onclick={handleClick}>
  {#each blocks as block, i (i)}
    {#if block.kind === "heading"}
      {@const tagLevel = Math.min(block.level + 2, 6)}
      <svelte:element this={`h${tagLevel}`} class="md-h{Math.min(block.level, 4)}">{@html renderInline(block.text)}</svelte:element>
    {:else if block.kind === "paragraph"}
      <p>{@html renderInline(block.text)}</p>
    {:else if block.kind === "list"}
      <ul class="md-list">
        {#each block.items as item, j (j)}
          <li style:--level={item.level} class:has-task={item.task !== null} class:done={item.task === true}>
            {#if item.task !== null}
              <span class="md-task" class:checked={item.task} aria-hidden="true">
                {#if item.task}<Icon name="check" size={10} />{/if}
              </span>
            {:else if item.number !== null}
              <span class="md-num" aria-hidden="true">{item.number}</span>
            {:else}
              <span class="md-bullet" aria-hidden="true">{item.level === 0 ? "•" : item.level === 1 ? "◦" : "▪"}</span>
            {/if}
            <span class="md-li-text">{@html renderInline(item.text)}</span>
          </li>
        {/each}
      </ul>
    {:else if block.kind === "code"}
      <MarkdownCode language={block.language} code={block.code} title={block.title} {baseFolder} {onrun} />
    {:else if block.kind === "mermaid"}
      {#if diagrams[i]}
        <div class="diagram">{@html diagrams[i]}</div>
      {:else}
        <MarkdownCode language="mermaid" code={block.code} />
      {/if}
    {:else if block.kind === "math"}
      {#if mathHtml[i] && mathOn}
        <div class="math-block">{@html mathHtml[i]}</div>
      {:else}
        <MarkdownCode language="math" code={block.tex} />
      {/if}
    {:else if block.kind === "details"}
      {@const isOpen = !!openDetails[i]}
      <div class="md-details" class:open={isOpen}>
        <button
          type="button"
          class="md-details-head"
          aria-expanded={isOpen}
          onclick={() => toggleDetails(i)}
        >
          <span class="md-chev" class:open={isOpen}><Icon name="chevron-right" size={12} /></span>
          <span class="md-details-summary">{@html renderInline(block.summary || tr("Details", "Details"))}</span>
        </button>
        {#if isOpen && block.body}
          <div class="md-details-body">
            <Markdown text={block.body} {baseFolder} {onrun} {citation} />
          </div>
        {/if}
      </div>
    {:else if block.kind === "image"}
      <MarkdownImage alt={block.alt} source={block.source} {baseFolder} />
    {:else if block.kind === "table"}
      <MarkdownTable header={block.header} rows={block.rows} {citation} />
    {:else if block.kind === "quote"}
      {#if block.callout}
        <div class="callout {block.callout.kind}">
          <span class="callout-icon"><Icon name={calloutIcon(block.callout.kind)} size={14} /></span>
          <div class="callout-content">
            <strong class="callout-title">{block.callout.title}</strong>
            {#if block.callout.body}
              <div class="callout-body">{@html renderInline(block.callout.body)}</div>
            {/if}
          </div>
        </div>
      {:else}
        <blockquote>{@html renderInline(block.text)}</blockquote>
      {/if}
    {:else if block.kind === "rule"}
      <hr class="md-rule" />
    {:else if block.kind === "pullRequest"}
      <p><a class="pr-link" href={block.url} data-external title={block.url}>{block.repo} #{block.number}</a></p>
    {/if}
  {/each}
</div>

<style>
  /* As the Mac sets an answer (`SelectableProse`): running text a step softer than headings, 10 px between blocks, a
     heading 6, 4 or 2 px over the text size by its level, with more room above than below. */
  .markdown {
    user-select: text;
    line-height: 1.55;
    color: var(--text-strong);
  }
  .markdown :global(p) {
    margin: 0 0 10px;
  }
  .markdown :global(p:last-child) {
    margin-bottom: 0;
  }
  .markdown :global(h3),
  .markdown :global(h4),
  .markdown :global(h5),
  .markdown :global(h6) {
    margin: 20px 0 6px;
    font-size: 1em;
    font-weight: 600;
    line-height: 1.3;
    color: var(--paper);
  }
  .markdown > :global(:first-child) { margin-top: 0; }
  .markdown :global(.md-h1) { font-size: 1.43em; }
  .markdown :global(.md-h2) { font-size: 1.29em; }
  .markdown :global(.md-h3) { font-size: 1.14em; }
  .markdown :global(a) {
    color: var(--iris);
  }
  .markdown :global(.link-host) {
    color: var(--text3);
    font-size: 0.92em;
  }
  .md-list {
    list-style: none;
    margin: 4px 0 10px;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .md-list:last-child {
    margin-bottom: 0;
  }
  .md-list li {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding-left: calc(var(--level, 0) * 18px);
  }
  .md-list li.done .md-li-text {
    color: var(--text3);
  }
  .md-bullet {
    flex: none;
    color: var(--text3);
    width: 12px;
    text-align: center;
  }
  .md-num {
    flex: none;
    color: var(--text2);
    font-variant-numeric: tabular-nums;
    min-width: 18px;
  }
  .md-task {
    flex: none;
    display: inline-grid;
    place-items: center;
    width: 14px;
    height: 14px;
    margin-top: 3px;
    border-radius: 4px;
    border: 1.5px solid var(--text3);
    color: var(--on-iris);
  }
  .md-task.checked {
    border-color: var(--iris);
    background: var(--iris);
  }
  .md-li-text {
    flex: 1;
    min-width: 0;
  }
  .md-details {
    margin: 6px 0 10px;
    border-top: 1px solid var(--line);
    border-bottom: 1px solid var(--line);
  }
  .md-details-head {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    padding: 8px 0;
    border: none;
    background: transparent;
    color: var(--text-strong);
    font-weight: 500;
    text-align: left;
  }
  .md-details-head:hover {
    background: transparent;
    color: var(--paper);
  }
  .md-chev {
    display: inline-flex;
    color: var(--text3);
    transition: transform 0.15s ease;
  }
  .md-chev.open {
    transform: rotate(90deg);
  }
  .md-details-body {
    padding: 0 0 10px 18px;
  }
  .callout {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    margin: 6px 0 10px;
    padding: 10px 12px;
    border-radius: var(--radius-panel);
    background: color-mix(in srgb, var(--iris) 8%, transparent);
  }
  .callout.note .callout-icon,
  .callout.note .callout-title {
    color: var(--iris);
  }
  .callout.tip {
    background: color-mix(in srgb, var(--mint) 8%, transparent);
  }
  .callout.tip .callout-icon,
  .callout.tip .callout-title {
    color: var(--mint);
  }
  .callout.warning {
    background: color-mix(in srgb, var(--amber) 8%, transparent);
  }
  .callout.warning .callout-icon,
  .callout.warning .callout-title {
    color: var(--amber);
  }
  .callout.danger {
    background: color-mix(in srgb, var(--coral) 8%, transparent);
  }
  .callout.danger .callout-icon,
  .callout.danger .callout-title {
    color: var(--coral);
  }
  .callout-icon {
    flex: none;
    margin-top: 2px;
    display: inline-flex;
  }
  .callout-content {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .callout-title {
    font-size: 13px;
    font-weight: 600;
  }
  .md-rule {
    border: none;
    border-top: 1px solid var(--line);
    margin: 10px 0;
  }
  .pr-link {
    display: inline-flex;
    padding: 3px 10px;
    border-radius: 999px;
    background: var(--smoke);
    font-size: 12px;
    text-decoration: none;
  }
  .diagram,
  .math-block {
    margin: 6px 0 10px;
    overflow-x: auto;
  }
</style>
