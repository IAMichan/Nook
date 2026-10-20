<script lang="ts">
  // Eén regel in de tijdlijn (`EventRow` op de Mac): berichten, het denken van de agent, tool-aanroepen met invoer en
  // uitkomst, gewijzigde bestanden, toestemmingsvragen, fouten, systeemregels en het einde van een beurt.
  import { renderMarkdown } from "../../../lib/markdown";
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

  const changeLabels: Record<string, string> = {
    added: "toegevoegd", modified: "gewijzigd", deleted: "verwijderd", renamed: "hernoemd", written: "geschreven",
  };

  function symbol(tool: string): string {
    switch (tool) {
      case "Bash": case "shell": case "BashOutput": case "KillShell": case "run_shell_command": return "›_";
      case "Read": case "NotebookRead": case "read_file": return "▤";
      case "Edit": case "MultiEdit": case "Write": case "NotebookEdit": case "write_file": case "replace": return "✎";
      case "Grep": case "Glob": return "⌕";
      case "WebFetch": case "WebSearch": case "web_search": return "◍";
      case "Task": case "Agent": return "⧉";
      case "TodoWrite": return "☑";
      default: return tool.startsWith("mcp") ? "⧠" : "⚒";
    }
  }

  const time = $derived(new Date(event.date).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }));
  const longThought = $derived(event.text.length > 280 || event.text.split("\n").length > 4);
  const approvalState: Record<string, string> = {
    pending: "wacht", allowed: "toegestaan", denied: "geweigerd", expired: "verlopen",
  };

  function copy(text: string) {
    navigator.clipboard?.writeText(text).catch(() => {});
  }
</script>

<div class="row" class:hl={highlighted}>
  {#if event.kind === "user"}
    <div class="msg user" oncontextmenu={(e) => { if (onrevert) { e.preventDefault(); onrevert(); } }} role="note">
      <div class="markdown">{@html renderMarkdown(event.text)}</div>
    </div>
  {:else if event.kind === "assistant"}
    <div class="msg assistant"><div class="markdown">{@html renderMarkdown(event.text)}</div></div>
  {:else if event.kind === "thinking"}
    <button class="thinking" onclick={toggle}>
      <span class="head"><span class="brain">✦</span> {event.state === "running" ? "Denkt na…" : "Denkstappen"}{#if longThought}<span class="chev" class:open={expanded}>›</span>{/if}</span>
      <span class="text" class:clamp={longThought && !expanded}>{event.text}</span>
    </button>
  {:else if event.kind === "tool"}
    <div class="tool">
      <button class="line" onclick={toggle} title="Klik om invoer en uitkomst te zien">
        <span class="state {event.state ?? 'done'}">{event.state === "running" ? "◌" : event.state === "failed" ? "✗" : "✓"}</span>
        <span class="sym">{symbol(event.tool ?? "")}</span>
        <span class="label">{event.text}</span>
        <span class="chev" class:open={expanded}>›</span>
      </button>
      {#if expanded}
        {#if event.detail && event.detail !== "{}"}
          <div class="code">
            <div class="code-head"><span>Invoer</span><button class="ghost tiny" onclick={() => copy(event.detail ?? "")}>Kopieer</button></div>
            <pre>{event.detail}</pre>
          </div>
        {/if}
        {#if event.output}
          <div class="code" class:failed={event.state === "failed"}>
            <div class="code-head"><span>Uitkomst</span><button class="ghost tiny" onclick={() => copy(event.output ?? "")}>Kopieer</button></div>
            <pre>{event.output}</pre>
          </div>
        {:else if event.state === "running"}
          <span class="faint small">Loopt nog…</span>
        {/if}
      {/if}
    </div>
  {:else if event.kind === "fileChange"}
    <button class="file" onclick={() => openFile?.(event.detail ?? event.text)} title="Open de diff">
      <span>▤</span><span class="mono">{event.text}</span><span class="faint">{changeLabels[event.tool ?? "modified"] ?? event.tool}</span><span class="faint">↗</span>
    </button>
  {:else if event.kind === "approval"}
    <button class="approval" onclick={toggle}>
      <span class="hand {event.state}">✋</span>
      <span>{event.tool ? toolLabel(event.tool) : "tool"} vraagt toestemming</span>
      <span class="mono faint label">{event.text}</span>
      <span class="st {event.state}">{approvalState[event.state ?? "pending"] ?? ""}</span>
    </button>
    {#if expanded && event.detail}<pre class="code-inline">{event.detail}</pre>{/if}
  {:else if event.kind === "error"}
    <div class="error"><span>⛔</span><span class="sel">{event.text}</span></div>
  {:else if event.kind === "system" && event.tool === "handoff"}
    <button class="system" onclick={toggle}><span>⇄</span><span class="label">{event.text}</span><span class="faint">{time}</span></button>
    {#if expanded}<pre class="code-inline">{event.detail ?? ""}</pre>{/if}
  {:else if event.kind === "system"}
    <div class="system"><span>{event.tool === "launch" ? "›_" : "ⓘ"}</span><span class="label sel">{event.text}</span><span class="faint">{time}</span></div>
  {:else if event.kind === "result"}
    <div class="result">
      <span class="rule"></span>
      <span>{event.state === "failed" ? "✗" : "✓"} {event.text ? `Beurt klaar · ${event.text}` : "Beurt klaar"}</span>
      <span class="rule"></span>
    </div>
  {/if}
</div>

<style>
  .row { border-radius: 8px; }
  .row.hl { background: rgba(244, 243, 247, 0.08); padding: 4px 0; }
  .msg { padding: 8px 12px; border-radius: 12px; max-width: 92%; }
  .msg.user { margin-left: auto; background: var(--smoke); width: fit-content; }
  .msg.assistant { padding-left: 0; }
  button { background: none; border: none; padding: 0; text-align: left; color: inherit; font: inherit; border-radius: 6px; }
  button:hover { background: none; }
  .thinking { display: flex; flex-direction: column; gap: 4px; padding-left: 10px; border-left: 2px solid rgba(244, 243, 247, 0.25); color: var(--text2); width: 100%; }
  .thinking .head { font-size: 12px; color: var(--text3); display: flex; gap: 6px; align-items: center; }
  .thinking .text { font-size: 12.5px; white-space: pre-wrap; opacity: 0.85; user-select: text; }
  .thinking .text.clamp { display: -webkit-box; -webkit-line-clamp: 4; line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; }
  .chev { display: inline-block; transition: transform 0.15s; color: var(--text3); margin-left: auto; }
  .chev.open { transform: rotate(90deg); }
  .tool { display: flex; flex-direction: column; gap: 6px; }
  .line { display: flex; gap: 8px; align-items: center; width: 100%; font-size: 12.5px; color: var(--text2); }
  .line:hover { color: var(--paper); }
  .state { width: 12px; font-size: 10px; }
  .state.done { color: var(--mint); opacity: 0.8; }
  .state.failed { color: var(--coral); }
  .state.running { color: var(--paper); animation: pulse 1.2s ease-in-out infinite; }
  .sym { width: 16px; color: var(--text3); font-family: var(--mono); font-size: 11px; }
  .label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .code { border: 1px solid var(--line2); border-radius: 8px; padding: 6px 8px; }
  .code.failed { border-color: rgba(255, 107, 107, 0.4); }
  .code-head { display: flex; justify-content: space-between; font-size: 10.5px; color: var(--text3); font-weight: 600; }
  .code pre, .code-inline { margin: 4px 0 0; font-family: var(--mono); font-size: 11.5px; white-space: pre-wrap; word-break: break-word; max-height: 320px; overflow: auto; user-select: text; }
  .code-inline { border: 1px solid var(--line2); border-radius: 8px; padding: 6px 8px; }
  .tiny { font-size: 10.5px; padding: 0 4px; }
  .file { display: flex; gap: 7px; align-items: center; font-size: 12px; color: var(--text2); }
  .file:hover { color: var(--paper); }
  .mono { font-family: var(--mono); font-size: 11.5px; }
  .approval { display: flex; gap: 8px; align-items: center; width: 100%; font-size: 12.5px; }
  .hand.pending, .st.pending { color: var(--amber); }
  .hand.allowed, .st.allowed { color: var(--mint); }
  .hand.denied, .st.denied { color: var(--coral); }
  .hand.expired, .st.expired { color: var(--text3); }
  .st { font-size: 11.5px; font-weight: 600; }
  .error { display: flex; gap: 8px; align-items: flex-start; font-size: 12.5px; color: var(--paper); background: rgba(255, 107, 107, 0.08); padding: 8px 10px; border-radius: 9px; }
  .sel { user-select: text; white-space: pre-wrap; word-break: break-word; }
  .system { display: flex; gap: 6px; align-items: center; font-size: 11.5px; color: var(--text3); width: 100%; }
  .result { display: flex; gap: 8px; align-items: center; font-size: 11.5px; color: var(--text3); }
  .result .rule { flex: 1; height: 1px; background: var(--line2); }
  .small { font-size: 11.5px; }
</style>
