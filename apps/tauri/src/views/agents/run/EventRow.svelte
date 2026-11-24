<script lang="ts">
  // Eén regel in de tijdlijn (`EventRow` op de Mac): berichten, het denken van de agent, tool-aanroepen met invoer en
  // uitkomst, subagents en achtergrondcommando's (AG-73), gewijzigde bestanden, toestemmingsvragen, fouten, systeemregels
  // en het einde van een beurt.
  import Icon from "../../../components/Icon.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import { isPicture, timeline } from "../../../lib/workspace/context-refs";
  import Markdown from "../../../components/Markdown.svelte";
  import MarkdownBody from "../../../components/MarkdownBody.svelte";
  import { tr, locale } from "../../../lib/i18n.svelte";
  import type { RunEvent } from "../../../lib/workspace/api";
  import {
    backgroundCommandFromEvent,
    backgroundCommandTail,
    backgroundLaunchNotice,
    subagentFromEvent,
    toolLabel,
  } from "../../../lib/workspace/timeline";

  let {
    event,
    expanded,
    toggle,
    highlighted = false,
    openFile,
    onrevert,
    onedit,
    onfork,
    baseFolder = null,
    onrun,
  }: {
    event: RunEvent;
    expanded: boolean;
    toggle: () => void;
    highlighted?: boolean;
    openFile?: (path: string) => void;
    onrevert?: () => void;
    /** Rewind the conversation to before this message and put it back in the composer (AG-62). */
    onedit?: () => void;
    /** A fork before this message of yours, or through this answer (`agents.fork.here`, `agents.fork.fromResponse`). */
    onfork?: () => void;
    baseFolder?: string | null;
    onrun?: (command: string, title: string | null) => void;
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

  // Your message without the envelope the agent got; what was attached shows as tiles.
  const shown = $derived(event.kind === "user" ? timeline(event.text, baseFolder) : { words: event.text, paths: [] as string[] });
  const time = $derived(new Date(event.date).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }));
  const longThought = $derived(event.text.length > 280 || event.text.split("\n").length > 4);
  const approvalState = $derived<Record<string, string>>({
    pending: tr("wacht", "waiting"), allowed: tr("toegestaan", "allowed"), denied: tr("geweigerd", "denied"), expired: tr("verlopen", "expired"),
  });

  // AG-73: Subagent row, background command row, and background launch notice
  const subagent = $derived(subagentFromEvent(event));
  const bgCommand = $derived(backgroundCommandFromEvent(event));
  const bgNoticeTasks = $derived(event.kind === "assistant" ? backgroundLaunchNotice(event.text) : []);

  let now = $state(Date.now());
  $effect(() => {
    if (!subagent?.isRunning && !bgCommand?.isRunning) return;
    const timer = setInterval(() => {
      now = Date.now();
    }, 1000);
    return () => clearInterval(timer);
  });

  function formatElapsed(isoDate: string): string {
    const secs = Math.max(0, Math.floor((now - Date.parse(isoDate)) / 1000));
    if (secs < 60) return `${secs}s`;
    const m = Math.floor(secs / 60);
    const s = secs % 60;
    return `${m}m ${s}s`;
  }

  function copy(text: string) {
    navigator.clipboard?.writeText(text).catch(() => {});
  }

  // Read aloud with the system voice (SV-52, matching `MessageView` / macOS `ReadAloudButton`); a second press stops it.
  let speaking = $state(false);
  function readAloud() {
    const synth = typeof window !== "undefined" ? window.speechSynthesis : undefined;
    if (!synth) return;
    if (speaking) {
      synth.cancel();
      speaking = false;
      return;
    }
    const plain = event.text.replace(/[*_`#>|]/g, "").trim();
    if (!plain) return;
    synth.cancel();
    const u = new SpeechSynthesisUtterance(plain);
    u.lang = locale();
    u.onend = u.onerror = () => (speaking = false);
    speaking = true;
    synth.speak(u);
  }
  $effect(() => () => {
    if (speaking) window.speechSynthesis?.cancel();
  });
</script>

<div class="row" class:hl={highlighted} class:rolled-back={event.rolledBack === true}>
  {#if event.kind === "user"}
    <!-- Your message: a round bubble on the right, its time and copy under it on hover. -->
    <div class="turn user">
      {#if event.tool === "steer"}
        <!-- "↪ Steer" marks a message that went into the turn while it ran (`SteerReceipts`): "waiting to be read" until
             the agent takes it in, "not read" when the turn ended first. -->
        <div class="steer"><Ico name="corner-up-right" size={12} stroke={2.2} />{event.state === "pending" ? tr("Bijgestuurd · wacht tot het gelezen is", "Steer · waiting to be read") : event.state === "expired" ? tr("Bijgestuurd · niet gelezen", "Steer · not read") : tr("Bijgestuurd", "Steer")}</div>
      {/if}
      {#if shown.paths.length}
        <!-- Files, folders and pictures sent with it, as tiles above the bubble (`ContextRefs.timeline`). -->
        <div class="sent-tiles">
          {#each shown.paths as path (path)}
            <span class="sent-tile" title={path}><Ico name={isPicture(path) ? "image" : /\.[a-z0-9]{1,6}$/i.test(path) ? "file" : "folder"} size={13} />{path.replace(/[\\/]+$/, "").split(/[\\/]/).pop()}</span>
          {/each}
        </div>
      {/if}
      {#if shown.words}
        <div class="msg user" oncontextmenu={(e) => { if (onrevert) { e.preventDefault(); onrevert(); } }} role="note">
          <Markdown text={shown.words} {baseFolder} {onrun} />
        </div>
      {/if}
      <div class="meta">
        {#if onedit}<button class="metab" title={tr("Bewerk vanaf hier", "Edit from here")} aria-label={tr("Bewerk vanaf hier", "Edit from here")} onclick={onedit}><Ico name="pencil" size={12} /></button>{/if}
        {#if onrevert}<button class="metab" title={tr("Zet de bestanden terug naar vóór dit bericht", "Restore the files to before this message")} onclick={onrevert}>{tr("Terugzetten", "Restore")}</button>{/if}
        {#if onfork}<button class="metab" title={tr("Vork vóór dit bericht", "Fork before this message")} aria-label={tr("Vork vóór dit bericht", "Fork before this message")} onclick={onfork}><Ico name="git-branch" size={12} /></button>{/if}
        <button class="metab" title={tr("Kopieer", "Copy")} aria-label={tr("Kopieer bericht", "Copy message")} onclick={() => copy(event.text)}><Icon name="copy" size={12} /></button>
        <span>{time}</span>
      </div>
    </div>
  {:else if event.kind === "assistant" && bgNoticeTasks.length > 0}
    <!-- Background launch notice ("task-148 has been launched in the background…") as a quiet work line (`BackgroundWork.notice` on macOS, AG-73). -->
    <div class="work-line" title={time}>
      <span class="work-icon"><Ico name="terminal" size={15} stroke={1.8} /></span>
      <span class="label">{tr("Op de achtergrond gestart · {tasks}", "Started in the background · {tasks}", { tasks: bgNoticeTasks.join(", ") })}</span>
    </div>
  {:else if event.kind === "assistant"}
    <!-- The agent's answer has no bubble at all. -->
    <div class="turn assistant">
      <div class="msg assistant"><MarkdownBody text={event.text} {baseFolder} {onrun} /></div>
      <div class="meta" class:speaking>
        <span>{time}</span>
        <button class="metab" title={tr("Kopieer", "Copy")} aria-label={tr("Kopieer antwoord", "Copy answer")} onclick={() => copy(event.text)}><Icon name="copy" size={12} /></button>
        {#if event.text.trim()}
          <button
            class="metab"
            class:speaking
            title={speaking ? tr("Stop met voorlezen", "Stop reading") : tr("Voorlezen", "Read aloud")}
            aria-label={speaking ? tr("Stop met voorlezen", "Stop reading") : tr("Voorlezen", "Read aloud")}
            onclick={readAloud}
          ><Ico name={speaking ? "square" : "volume-2"} size={12} /></button>
        {/if}
        {#if onfork}<button class="metab" title={tr("Vork vanaf dit antwoord", "Fork from this response")} aria-label={tr("Vork vanaf dit antwoord", "Fork from this response")} onclick={onfork}><Ico name="git-branch" size={12} /></button>{/if}
      </div>
    </div>
  {:else if event.kind === "thinking"}
    <button class="thinking" onclick={toggle}>
      <span class="head"><Icon name="brain" size={13} /> {event.state === "running" ? tr("Denkt na…", "Thinking…") : tr("Denkstappen", "Thinking")}{#if longThought}<span class="chev" class:open={expanded}><Icon name="chevron-right" size={12} /></span>{/if}</span>
      <span class="text" class:clamp={longThought && !expanded}>{event.text}</span>
    </button>
  {:else if event.kind === "tool" && subagent}
    <!-- SubagentRow (`RunTimelineRows.swift` on macOS, AG-73) -->
    <div class="tool subagent-row">
      <button class="line" onclick={toggle} title={tr("Klik om opdracht en antwoord van subagent te zien", "Click to see subagent task and answer")}>
        <span class="sym {subagent.failed ? 'failed' : subagent.isRunning ? 'running' : 'done'}">
          {#if subagent.isRunning}
            <span class="spin"><Icon name="loader" size={13} /></span>
          {:else if subagent.failed}
            <Icon name="x" size={13} />
          {:else}
            <Icon name="bot" size={13} />
          {/if}
        </span>
        <span class="label"><strong>{subagent.title}</strong></span>
        <span class="subagent-kind">{subagent.kind}</span>
        {#if subagent.background}
          <span class="subagent-bg">{tr("achtergrond", "background")}</span>
        {/if}
        {#if subagent.isRunning}
          <span class="subagent-elapsed">{formatElapsed(subagent.started)}</span>
        {/if}
        <span class="chev" class:open={expanded}><Icon name="chevron-right" size={12} /></span>
      </button>
      {#if expanded}
        {#if subagent.prompt}
          <div class="code">
            <div class="code-head"><span>{tr("Opdracht", "Task")}</span><button class="ghost tiny" onclick={() => copy(subagent.prompt)}>{tr("Kopieer", "Copy")}</button></div>
            <pre>{subagent.prompt}</pre>
          </div>
        {/if}
        {#if subagent.answer}
          <div class="code" class:failed={subagent.failed}>
            <div class="code-head"><span>{tr("Antwoord", "Answer")}</span><button class="ghost tiny" onclick={() => copy(subagent.answer ?? "")}>{tr("Kopieer", "Copy")}</button></div>
            <pre>{subagent.answer}</pre>
          </div>
        {:else if subagent.isRunning}
          <span class="faint small subagent-status">{tr("Subagent werkt…", "Subagent is working…")}</span>
        {/if}
      {/if}
    </div>
  {:else if event.kind === "tool"}
    <div class="tool">
      <button class="line" onclick={toggle} title={tr("Klik om invoer en uitkomst te zien", "Click to see input and output")}>
        <span class="sym {event.state ?? 'done'}">{#if event.state === "running"}<span class="spin"><Icon name="loader" size={13} /></span>{:else if event.state === "failed"}<Icon name="x" size={13} />{:else}<Icon name={symbol(event.tool ?? "")} size={13} />{/if}</span>
        <span class="label">{event.text}</span>
        {#if bgCommand}
          <span class="subagent-bg">{bgCommand.isRunning ? tr("Op de achtergrond · {time}", "In the background · {time}", { time: formatElapsed(bgCommand.started) }) : tr("Achtergrond", "Background")}</span>
        {/if}
        <span class="chev" class:open={expanded}><Icon name="chevron-right" size={12} /></span>
      </button>
      {#if bgCommand && !expanded}
        {@const tail = backgroundCommandTail(bgCommand.printed, 1)}
        {#if tail}
          <button class="bg-cmd-link" onclick={toggle}>
            <span class="mono">{tail}</span>
          </button>
        {/if}
      {/if}
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
            <pre>{bgCommand?.printed ?? event.output}</pre>
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
    <button class="work-line link" onclick={toggle} title={time}><span class="work-icon"><Ico name="arrow-left-right" size={16} stroke={1.8} /></span><span class="label">{event.text}</span><span class="chev" class:open={expanded}><Ico name="chevron-right" size={12} stroke={2.5} /></span></button>
    {#if expanded}<pre class="code-inline">{event.detail ?? ""}</pre>{/if}
  {:else if event.kind === "system" && event.tool === "clear"}
    <!-- `/clear` (`TimelineNewDivider`): the agent remembers nothing above this line. -->
    <div class="new-divider" title={time}><span class="rule"></span><span>{event.text}</span><span class="rule"></span></div>
  {:else if event.kind === "system" && event.tool === "compaction"}
    <!-- Context compaction status (AG-65): spinning while running, compact icon when done, muted failure when stopped. -->
    <div class="work-line" class:compacting={event.state === "running"} class:failed={event.state === "failed"} title={time}>
      <span class="work-icon">
        {#if event.state === "running"}
          <span class="spin"><Ico name="loader-circle" size={15} stroke={2} /></span>
        {:else if event.state === "failed"}
          <Ico name="circle-alert" size={15} stroke={1.8} />
        {:else}
          <Ico name="minimize-2" size={15} stroke={1.8} />
        {/if}
      </span>
      <span class="label sel">{event.state === "running" && !event.text ? tr("Vat het gesprek samen…", "Compacting the conversation…") : event.text}</span>
    </div>
  {:else if event.kind === "system"}
    <!-- A note in the conversation as one quiet work line (`TranscriptWorkLine`): who started the session ("origin"),
         the command Nook launched, the session goal ("goal"), or another note; no time, as on the Mac. -->
    <div class="work-line" title={time}>
      <span class="work-icon"><Ico name={event.tool === "origin" ? "corner-right-down" : event.tool === "launch" ? "terminal" : event.tool === "goal" ? "target" : "info"} size={16} stroke={1.8} /></span>
      <span class="label sel" class:mono={event.tool === "launch"}>{event.text}</span>
    </div>
  {:else if event.kind === "result" && event.state === "failed"}
    <!-- The end of a turn says nothing of its own (the fold above says how long it worked); only a failed turn gets a line. -->
    <div class="work-line failed">
      <span class="work-icon"><Ico name="circle-alert" size={16} stroke={1.8} /></span>
      <span class="label">{event.text ? tr("Beurt mislukt: {reason}", "Turn failed: {reason}", { reason: event.text }) : tr("Beurt mislukt", "Turn failed")}</span>
      <Ico name="x" size={11} stroke={3} />
    </div>
  {/if}
</div>

<style>
  .row { border-radius: var(--radius-control); }
  .row.hl { background: color-mix(in srgb, var(--iris) 8%, transparent); }
  .row.rolled-back { opacity: 0.45; }
  .turn { display: flex; flex-direction: column; gap: 4px; }
  .turn.user { align-items: flex-end; }
  .msg { font-size: 14px; line-height: 1.6; }
  .msg.user { max-width: 80%; padding: 8px 12px; border-radius: var(--radius-composer); background: var(--bubble); color: var(--paper); }
  .msg.assistant { padding: 2px 0; color: var(--text-strong); }
  .meta { display: flex; align-items: center; gap: 6px; padding: 0 4px; min-height: 20px; font-size: 12px; color: var(--text3); font-variant-numeric: tabular-nums; opacity: 0; transition: opacity 200ms ease; }
  .turn:hover .meta, .meta:focus-within, .meta.speaking { opacity: 1; }
  .metab { display: inline-flex; align-items: center; padding: 2px 4px; border-radius: var(--radius-chip); color: var(--text3); font-size: 12px; }
  .metab:hover, .metab.speaking { color: var(--paper); background: var(--row-hover); }
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
  .sent-tiles { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: var(--space-6); max-width: 80%; }
  .sent-tile { display: inline-flex; align-items: center; gap: var(--space-6); height: 26px; padding: 0 var(--space-8); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--smoke); font: var(--text-detail); color: var(--text2); }
  .steer { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-label); color: var(--text2); }
  .new-divider { display: flex; align-items: center; gap: var(--space-12); font: var(--text-label); color: var(--text3); }
  .new-divider .rule { flex: 1; height: 1px; background: var(--separator); }
  /* `TranscriptWorkLine`: the icon in tertiary, the words in secondary body text, 24 pt tall. */
  .work-line { display: flex; gap: var(--space-8); align-items: center; min-height: 24px; font: var(--text-body); color: var(--text2); }
  .work-line.link:hover { color: var(--paper); }
  .work-line.link:hover .chev { opacity: 1; }
  .work-icon { display: inline-flex; width: 16px; justify-content: center; flex: none; color: var(--text3); }
  .work-line.compacting, .work-line.compacting .work-icon { color: var(--amber); }
  .work-line.failed, .work-line.failed .work-icon { color: color-mix(in srgb, var(--coral) 60%, transparent); }
  .small { font-size: 11.5px; }
  .subagent-kind { font: var(--text-caption); color: var(--text3); padding: 1px var(--space-6); border-radius: var(--radius-chip); background: var(--smoke); flex: none; }
  .subagent-bg { font: var(--text-caption); color: var(--text3); flex: none; font-variant-numeric: tabular-nums; }
  .subagent-elapsed { font: var(--text-caption); color: var(--text3); flex: none; font-variant-numeric: tabular-nums; }
  .subagent-status { margin-left: 25px; }
  .bg-cmd-link { margin-left: 25px; padding: 2px var(--space-8); border-radius: var(--radius-control); background: var(--well); border: 1px solid var(--line2); color: var(--text3); max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .bg-cmd-link:hover { color: var(--paper); }
</style>
