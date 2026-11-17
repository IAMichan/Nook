<script lang="ts">
  // A fenced code block (`MarkdownCodeBlock` & `CodeRenderView` on the Mac): optional file name or language on the
  // left; Preview/Source (for HTML/SVG in a sandboxed iframe), Wrap, Run in terminal (for shell blocks in a session
  // folder) and Copy on the right.
  import { untrack } from "svelte";
  import { tr } from "../lib/i18n.svelte";
  import { canPreviewCode, previewSrcdoc } from "../lib/markdown-blocks";
  import { canRunCode, highlightCodeToHtml, isShellLanguage, shellCommand } from "../lib/syntax";
  import { toolsApi } from "../lib/workspace/api";
  import { toast } from "../lib/toast.svelte";
  import Icon from "./Icon.svelte";

  let {
    language,
    code,
    title = null,
    baseFolder = null,
    onrun,
  }: {
    language: string;
    code: string;
    title?: string | null;
    baseFolder?: string | null;
    onrun?: (command: string, title: string | null) => void;
  } = $props();

  let rendered = $state(false);
  let wraps = $state(false);
  let copied = $state(false);
  let shownSrcdoc = $state("");

  const canPreview = $derived(canPreviewCode(language));
  const runnable = $derived(!!baseFolder && isShellLanguage(language) && canRunCode(code));
  const highlighted = $derived(rendered ? null : highlightCodeToHtml(code, language, title));
  const headerTip = $derived(title ? (language ? `${title} · ${language}` : title) : language || "code");

  // Debounce sandboxed preview updates while a code block streams in (300 ms, matching CodeRender.swift).
  let previewTimer: ReturnType<typeof setTimeout> | null = null;
  $effect(() => {
    const active = rendered && canPreview;
    const lang = language;
    const body = code;
    if (!active) {
      if (previewTimer) {
        clearTimeout(previewTimer);
        previewTimer = null;
      }
      return;
    }
    const nextDoc = previewSrcdoc(lang, body);
    const current = untrack(() => shownSrcdoc);
    if (!current) {
      shownSrcdoc = nextDoc;
      return;
    }
    if (previewTimer) clearTimeout(previewTimer);
    previewTimer = setTimeout(() => {
      shownSrcdoc = nextDoc;
      previewTimer = null;
    }, 300);
    return () => {
      if (previewTimer) {
        clearTimeout(previewTimer);
        previewTimer = null;
      }
    };
  });

  async function copyCode() {
    try {
      await navigator.clipboard?.writeText(code);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      // Clipboard may be unavailable.
    }
  }

  async function runBlock() {
    if (!baseFolder || !runnable) return;
    const cmd = shellCommand(code);
    if (onrun) {
      onrun(cmd, title);
      return;
    }
    try {
      await toolsApi.openTerminal(baseFolder, cmd, title);
      toast.success(tr("Gestart in terminal", "Started in terminal"));
    } catch (e) {
      toast.error(tr("Kon terminal niet openen", "Could not open terminal"), e);
    }
  }
</script>

<div class="code-block">
  <div class="code-head">
    <div class="code-id" title={headerTip}>
      {#if title}
        <Icon name="file" size={11} />
        <span class="code-title">{title}</span>
      {:else}
        <span class="code-lang">{language || "code"}</span>
      {/if}
    </div>
    <div class="code-actions">
      {#if canPreview}
        <button
          type="button"
          class="code-btn"
          class:active={rendered}
          aria-pressed={rendered}
          title={rendered ? tr("Bron", "Source") : tr("Bekijk", "Preview")}
          aria-label={rendered ? tr("Bron", "Source") : tr("Bekijk", "Preview")}
          onclick={() => (rendered = !rendered)}
        >
          <Icon name={rendered ? "code" : "eye"} size={13} />
        </button>
      {/if}
      {#if !rendered}
        <button
          type="button"
          class="code-btn"
          class:active={wraps}
          aria-pressed={wraps}
          title={wraps ? tr("Regels niet laten teruglopen", "Don't wrap lines") : tr("Regels laten teruglopen", "Wrap lines")}
          aria-label={wraps ? tr("Regels niet laten teruglopen", "Don't wrap lines") : tr("Regels laten teruglopen", "Wrap lines")}
          onclick={() => (wraps = !wraps)}
        >
          <Icon name="wrap" size={13} />
        </button>
      {/if}
      {#if runnable}
        <button
          type="button"
          class="code-btn"
          title={tr("Uitvoeren in terminal", "Run in terminal")}
          aria-label={tr("Uitvoeren in terminal", "Run in terminal")}
          onclick={runBlock}
        >
          <Icon name="play" size={12} />
        </button>
      {/if}
      <button
        type="button"
        class="code-btn"
        class:copied
        title={copied ? tr("Gekopieerd", "Copied") : tr("Code kopiëren", "Copy code")}
        aria-label={copied ? tr("Gekopieerd", "Copied") : tr("Code kopiëren", "Copy code")}
        onclick={copyCode}
      >
        <Icon name={copied ? "check" : "copy"} size={12} />
      </button>
    </div>
  </div>

  {#if rendered && canPreview}
    <div class="preview-wrap">
      <iframe class="code-preview" sandbox="" title={title || language || "preview"} srcdoc={shownSrcdoc}></iframe>
    </div>
  {:else}
    <pre class:wrap={wraps}><code data-lang={language || undefined}>{#if highlighted !== null}{@html highlighted}{:else}{code}{/if}</code></pre>
  {/if}
</div>

<style>
  .code-block {
    margin: 0 0 10px;
    background: var(--well);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    overflow: hidden;
  }
  .code-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 6px 8px 4px 12px;
  }
  .code-id {
    display: flex;
    align-items: center;
    gap: 5px;
    min-width: 0;
    font-family: var(--mono);
    font-size: 11px;
    color: var(--text3);
  }
  .code-title {
    color: var(--text2);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    direction: rtl;
    text-align: left;
  }
  .code-lang {
    color: var(--text3);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .code-actions {
    display: flex;
    align-items: center;
    gap: 2px;
    flex: none;
  }
  .code-btn {
    display: inline-grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: var(--text3);
  }
  .code-btn:hover {
    background: var(--row-hover);
    color: var(--paper);
  }
  .code-btn.active {
    background: var(--smoke);
    color: var(--paper);
  }
  .code-btn.copied {
    color: var(--mint);
  }
  .code-block pre {
    margin: 0;
    padding: 4px 12px 12px;
    border: none;
    border-radius: 0;
    background: transparent;
    overflow-x: auto;
    white-space: pre;
    font-family: var(--mono);
    font-size: 12.5px;
    line-height: 1.45;
  }
  .code-block pre.wrap {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    overflow-x: visible;
  }
  .code-block pre code {
    background: none;
    padding: 0;
    font-size: inherit;
    color: var(--text-strong);
  }
  .preview-wrap {
    padding: 6px 8px 8px;
  }
  .code-preview {
    display: block;
    width: 100%;
    height: 280px;
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
    background: #ffffff;
  }
</style>
