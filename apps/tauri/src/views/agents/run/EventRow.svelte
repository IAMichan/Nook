<script lang="ts">
  // Eén regel in de tijdlijn (`EventRow` op de Mac): berichten, het denken van de agent, tool-aanroepen met invoer en
  // uitkomst, gewijzigde bestanden, toestemmingsvragen, fouten, systeemregels en het einde van een beurt.
  import Icon from "../../../components/Icon.svelte";
  import { renderMarkdown } from "../../../lib/markdown";
  import { tr, locale } from "../../../lib/i18n.svelte";
  import type { RunEvent } from "../../../lib/workspace/api";
  import { toolLabel } from "../../../lib/workspace/timeline";

  let {
    event,
    expanded,
    toggle,
    highlighted = false,
    openFile,
    onrevert,
  }: {
    event: RunEvent;
    expanded: boolean;
    toggle: () => void;
    highlighted?: boolean;
    openFile?: (path: string) => void;
    onrevert?: () => void;
  } = $props();

  const changeLabels = $derived<Record<string, string>>({
    added: tr("toegevoegd", "added"), modified: tr("gewijzigd", "modified"), deleted: tr("verwijderd", "deleted"), renamed: tr("hernoemd", "renamed"), written: tr("geschreven", "written"),
  });

  type ToolIcon = "terminal" | "file" | "pencil" | "search" | "globe" | "bot" | "tasks" | "link" | "wrench";
  /// The Lucide icon for each kind of tool call.
  function symbol(tool: string): ToolIcon {
    switch (tool) {
      case "Bash": case "shell": case "BashOutput": case "KillShell": case "run_shell_command": return "terminal";
      case "Read": case "NotebookRead": case "read_file": return "file";
      case "Edit": case "MultiEdit": case "Write": case "NotebookEdit": case "write_file": case "replace": return "pencil";
      case "Grep": case "Glob": return "search";
      case "WebFetch": case "WebSearch": case "web_search": return "globe";
      case "Task": case "Agent": return "bot";
      case "TodoWrite": return "tasks";
      default: return tool.startsWith("mcp") ? "link" : "wrench";
    }
  }

  const time = $derived(new Date(event.date).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }));
  const longThought = $derived(event.text.length > 280 || event.text.split("\n").length > 4);
  const approvalState = $derived<Record<string, string>>({
    pending: tr("wacht", "waiting"), allowed: tr("toegestaan", "allowed"), denied: tr("geweigerd", "denied"), expired: tr("verlopen", "expired"),
  });

  function copy(text: string) {
    navigator.clipboard?.writeText(text).catch(() => {});
  }
</script>

<div class="row" class:hl={highlighted}>
  {#if event.kind === "user"}
    <!-- Your message: a round bubble on the right, its time and copy under it on hover. -->
    <div class="turn user">
      <div class="msg user" oncontextmenu={(e) => { if (onrevert) { e.preventDefault(); onrevert(); } }} role="note">
        <div class="markdown">{@html renderMarkdown(event.text)}</div>
      </div>
      <div class="meta">
        {#if onrevert}<button class="metab" title={tr("Zet de bestanden terug naar vóór dit bericht", "Restore the files to before this message")} onclick={onrevert}>{tr("Terugzetten", "Restore")}</button>{/if}
        <button class="metab" title={tr("Kopieer", "Copy")} aria-label={tr("Kopieer bericht", "Copy message")} onclick={() => copy(event.text)}><Icon name="copy" size={12} /></button>
        <span>{time}</span>
      </div>
    </div>
  {:else if event.kind === "assistant"}
    <!-- The agent's answer has no bubble at all. -->
    <div class="turn assistant">
      <div class="msg assistant"><div class="markdown">{@html renderMarkdown(event.text)}</div></div>
      <div class="meta">
        <span>{time}</span>
        <button class="metab" title={tr("Kopieer", "Copy")} aria-label={tr("Kopieer antwoord", "Copy answer")} onclick={() => copy(event.text)}><Icon name="copy" size={12} /></button>
      </div>
    </div>
  {:else if event.kind === "thinking"}
    <button class="thinking" onclick={toggle}>
      <span class="head"><Icon name="brain" size={13} /> {event.state === "running" ? tr("Denkt na…", "Thinking…") : tr("Denkstappen", "Thinking")}{#if longThought}<span class="chev" class:open={expanded}><Icon name="chevron-right" size={12} /></span>{/if}</span>
      <span class="text" class:clamp={longThought && !expanded}>{event.text}</span>
    </button>
  {:else if event.kind === "tool"}
    <div class="tool">
      <button class="line" onclick={toggle} title={tr("Klik om invoer en uitkomst te zien", "Click to see input and output")}>
        <span class="sym {event.state ?? 'done'}">{#if event.state === "running"}<span class="spin"><Icon name="loader" size={13} /></span>{:else if event.state === "failed"}<Icon name="x" size={13} />{:else}<Icon name={symbol(event.tool ?? "")} size={13} />{/if}</span>
        <span class="label">{event.text}</span>
        <span class="chev" class:open={expanded}><Icon name="chevron-right" size={12} /></span>
      </button>
      {#if expanded}
        {#if event.detail && event.detail !== "{}"}
          <div class="code">
            <div class="code-head"><span>{tr("Invoer", "Input")}</span><button class="ghost tiny" onclick={() => copy(event.detail ?? "")}>{tr("Kopieer", "Copy")}</button></div>
            <pre>{event.detail}</pre>
          </div>
        {/if}
        {#if event.output}
          <div class="code" class:failed={event.state === "failed"}>
            <div class="code-head"><span>{tr("Uitkomst", "Output")}</span><button class="ghost tiny" onclick={() => copy(event.output ?? "")}>{tr("Kopieer", "Copy")}</button></div>
            <pre>{event.output}</pre>
          </div>
        {:else if event.state === "running"}
          <span class="faint small">{tr("Loopt nog…", "Still running…")}</span>
        {/if}
      {/if}
    </div>
  {:else if event.kind === "fileChange"}
    <button class="file" onclick={() => openFile?.(event.detail ?? event.text)} title={tr("Open de diff", "Open the diff")}>
      <span class="sym"><Icon name="pencil" size={13} /></span><span class="mono">{event.text}</span><span class="faint">{changeLabels[event.tool ?? "modified"] ?? event.tool}</span>
    </button>
  {:else if event.kind === "approval"}
    <button class="approval" onclick={toggle}>
      <span class="hand {event.state}"><Icon name="hand" size={13} /></span>
      <span>{tr("{tool} vraagt toestemming", "{tool} asks for permission", { tool: event.tool ? toolLabel(event.tool) : "tool" })}</span>
      <span class="mono faint label">{event.text}</span>
      <span class="st {event.state}">{approvalState[event.state ?? "pending"] ?? ""}</span>
    </button>
    {#if expanded && event.detail}<pre class="code-inline">{event.detail}</pre>{/if}
  {:else if event.kind === "error"}
    <div class="error"><span class="esym"><Icon name="alert" size={14} /></span><span class="sel">{event.text}</span></div>
  {:else if event.kind === "system" && event.tool === "handoff"}
    <button class="system" onclick={toggle}><span>⇄</span><span class="label">{event.text}</span><span class="faint">{time}</span></button>
    {#if expanded}<pre class="code-inline">{event.detail ?? ""}</pre>{/if}
  {:else if event.kind === "system"}
    <div class="system"><span>{event.tool === "launch" ? "›_" : "ⓘ"}</span><span class="label sel">{event.text}</span><span class="faint">{time}</span></div>
  {:else if event.kind === "result"}
    <div class="result">
      <span class="rule"></span>
      <span>{event.state === "failed" ? tr("Beurt mislukt", "Turn failed") : tr("Beurt klaar", "Turn done")}{event.text ? ` · ${event.text}` : ""}</span>
      <span class="rule"></span>
    </div>
  {/if}
</div>

<style>
  .row { border-radius: var(--radius-control); }
  .row.hl { background: color-mix(in srgb, var(--iris) 8%, transparent); }
  .turn { display: flex; flex-direction: column; gap: 4px; }
  .turn.user { align-items: flex-end; }
  .msg { font-size: 14px; line-height: 1.6; }
  .msg.user { max-width: 80%; padding: 8px 12px; border-radius: var(--radius-composer); background: var(--bubble); color: var(--paper); }
  .msg.assistant { padding: 2px 4px; color: var(--text-strong); }
  .meta { display: flex; align-items: center; gap: 6px; padding: 0 4px; min-height: 20px; font-size: 12px; color: var(--text3); font-variant-numeric: tabular-nums; opacity: 0; transition: opacity 200ms ease; }
  .turn:hover .meta, .meta:focus-within { opacity: 1; }
  .metab { display: inline-flex; align-items: center; padding: 2px 4px; border-radius: var(--radius-chip); color: var(--text3); font-size: 12px; }
  .metab:hover { color: var(--paper); background: var(--row-hover); }
  button { background: none; border: none; padding: 0; text-align: left; color: inherit; font: inherit; border-radius: 6px; }
  button:hover { background: none; }
  .thinking { display: flex; flex-direction: column; gap: 4px; padding: 0 4px; color: var(--text2); width: 100%; }
  .thinking .head { font-size: 14px; color: var(--text2); display: flex; gap: 8px; align-items: center; min-height: 24px; }
  .thinking .text { font-size: 13px; line-height: 1.6; white-space: pre-wrap; color: var(--text3); margin-left: 21px; user-select: text; }
  .thinking .text.clamp { display: -webkit-box; -webkit-line-clamp: 4; line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; }
  .chev { display: inline-flex; transition: transform 0.15s; color: var(--text3); opacity: 0; }
  .line:hover .chev, .thinking:hover .chev, .chev.open { opacity: 1; }
  .chev.open { transform: rotate(90deg); }
  /* A tool call as a work entry: its icon and what it did on one 24 px line, the details under it when opened. */
  .tool { display: flex; flex-direction: column; gap: 6px; }
  .line { display: flex; gap: 8px; align-items: center; min-height: 24px; width: 100%; padding: 0 4px; font-size: 14px; color: var(--text2); }
  .line:hover { color: var(--paper); }
  .sym { display: inline-flex; flex: none; color: var(--text3); }
  .sym.failed { color: var(--coral); }
  .spin { display: inline-flex; animation: spin 1s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .code { border: 1px solid var(--line2); border-radius: var(--radius-card); padding: 6px 10px; margin-left: 25px; background: var(--well); }
  .code.failed { border-color: color-mix(in srgb, var(--coral) 40%, var(--line2)); }
  .code-head { display: flex; justify-content: space-between; font-size: 10.5px; color: var(--text3); font-weight: 600; }
  .code pre, .code-inline { margin: 4px 0 0; font-family: var(--mono); font-size: 11.5px; white-space: pre-wrap; word-break: break-word; max-height: 320px; overflow: auto; user-select: text; }
  .code-inline { border: 1px solid var(--line2); border-radius: var(--radius-card); padding: 6px 10px; background: var(--well); }
  .tiny { font-size: 10.5px; padding: 0 4px; }
  .file { display: flex; gap: 8px; align-items: center; min-height: 24px; padding: 0 4px; font-size: 13px; color: var(--text2); }
  .file:hover { color: var(--paper); }
  .mono { font-family: var(--mono); font-size: 11.5px; }
  .approval { display: flex; gap: 8px; align-items: center; min-height: 24px; width: 100%; padding: 0 4px; font-size: 14px; color: var(--text2); }
  .hand { display: inline-flex; }
  .hand.pending, .st.pending { color: var(--amber); }
  .hand.allowed, .st.allowed { color: var(--mint); }
  .hand.denied, .st.denied { color: var(--coral); }
  .hand.expired, .st.expired { color: var(--text3); }
  .st { font-size: 11.5px; font-weight: 600; }
  .error { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: var(--paper); background: var(--surface); border: 1px solid color-mix(in srgb, var(--coral) 35%, var(--line2)); padding: 8px 12px; border-radius: var(--radius-card); }
  .esym { display: inline-flex; color: var(--coral); margin-top: 1px; }
  .sel { user-select: text; white-space: pre-wrap; word-break: break-word; }
  .system { display: flex; gap: 6px; align-items: center; padding: 0 4px; font-size: 12px; color: var(--text3); width: 100%; }
  /* The end of a turn as a system divider: a hairline with the words in the middle. */
  .result { display: flex; gap: 12px; align-items: center; font-size: 12px; color: var(--text3); font-variant-numeric: tabular-nums; }
  .result .rule { flex: 1; height: 1px; background: var(--line); }
  .small { font-size: 11.5px; }
</style>
