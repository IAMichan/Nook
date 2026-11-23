<script lang="ts">
  // Een sessie die Nook via hooks of de proceslijst kent (`AgentSessionDetail` op de Mac): wat hij doet, wat hij
  // vraagt, het gesprek uit zijn transcript, en de knoppen om naar zijn terminal te gaan, hem over te nemen of te
  // beëindigen.
  import { agentApi, statusLabels, type AgentSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ApprovalCard from "./ApprovalCard.svelte";
  import Conversation from "./Conversation.svelte";
  import ActionSuggestionBar from "../../components/ActionSuggestionBar.svelte";
  import DiffView from "./DiffView.svelte";
  import GrantedRulesSheet from "./GrantedRulesSheet.svelte";
  import QuestionCard from "./QuestionCard.svelte";
  import { ago } from "./time";
  import SessionAnnouncer from "../../components/SessionAnnouncer.svelte";

  let { session, ontakeover }: { session: AgentSession; ontakeover?: (s: AgentSession, endTerminal: boolean, message?: string) => void } = $props();
  let canEnd = $state(false);
  let terminalName = $state("terminal");
  let message = $state("");
  let error = $state<string | null>(null);
  let showPermissions = $state(false);
  let replyInput = $state<HTMLInputElement | null>(null);

  $effect(() => {
    agentApi.canEnd(session.id).then((v) => (canEnd = v));
    agentApi.terminalName(session.host).then((n) => (terminalName = n));
  });

  function appendPaths(paths: string[]) {
    if (!paths.length) return;
    const joined = paths.join(" ");
    const cur = message.trim();
    message = cur ? `${cur} ${joined}` : `${joined} `;
    requestAnimationFrame(() => replyInput?.focus());
  }

  $effect(() => {
    const queued = agents.takeDroppedFiles(session.id);
    if (queued.length) appendPaths(queued);
  });

  $effect(() => {
    const handler = (e: Event) => {
      const detail = (e as CustomEvent<{ id: string; paths: string[] }>).detail;
      if (detail?.id === session.id && detail.paths?.length) {
        agents.takeDroppedFiles(session.id);
        appendPaths(detail.paths);
      }
    };
    window.addEventListener("nook-agents-drop-files", handler);
    return () => window.removeEventListener("nook-agents-drop-files", handler);
  });

  const approval = $derived(agents.approvalFor(session.id));
  const question = $derived(agents.questionFor(session.id));
  const canNook = $derived(["Claude Code", "Claude (app)", "Codex", "Gemini CLI"].includes(session.name) && !!session.cwd);
  const busy = $derived(session.status === "running" || session.status === "waiting");
  // "Started by an agent in …" (`LauncherLink`): the session whose shell started this one, as a link that opens it.
  const launcher = $derived(session.launchedBy ? agents.sessions.find((s) => s.id === session.launchedBy) : undefined);

  async function end() {
    if (!(await ask({
      question: tr("{name} in {project} beëindigen?", "End {name} in {project}?", { name: session.name, project: session.project }),
      detail: tr("De agent bewaart zijn gesprek, zodat je later verder kunt.", "The agent keeps its conversation, so you can continue later."),
      confirmTitle: tr("Beëindig sessie", "End session"),
    }))) return;
    try {
      await agentApi.end(session.id);
    } catch (e) {
      error = String(e);
    }
  }

  async function terminal() {
    try {
      await agentApi.activateTerminal(session.host);
    } catch {
      error = tr("Ik vind de terminal van {name} niet. Staat hij nog open?", "I can't find the terminal of {name}. Is it still open?", { name: session.name });
    }
  }

  function send() {
    const text = message.trim();
    if (!text || !ontakeover) return;
    ontakeover(session, false, text);
    message = "";
  }
</script>

<div class="detail">
  <!-- Settings › Sessions › Screen reader announcements (`AgentAnnouncer` on the Mac): the agent's last reply, what waits
       on you and its step, from the hooks' report (the transcript itself is drawn by Conversation). -->
  <SessionAnnouncer sessionId={session.id} author={session.name}
    events={session.lastReply ? [{ id: `reply:${session.lastReply}`, date: "", kind: "assistant", text: session.lastReply }] : []}
    status={approval || session.approvalId ? "approval" : question || session.questionId ? "question" : session.status === "running" ? "working" : "idle"}
    step={session.status === "running" ? (session.steps[session.steps.length - 1]?.text ?? null) : null} />
  <header class="thread-head">
    <div class="title"><span class="project">{session.project}</span><span class="slash">/</span><span class="name">{session.lastPrompt || session.summary || session.name}</span></div>
    <div class="meta faint">
      <span class="dot {session.status === 'waiting' ? 'waiting' : session.status === 'running' ? 'working' : session.status === 'failed' ? 'error' : session.status === 'done' ? 'unread' : ''}"></span>
      {session.name} · {session.compacting ? tr("Het gesprek wordt samengevat…", "Compacting the conversation…") : statusLabels[session.status]}{#if session.updated} · {ago(session.updated)}{/if}
      {#if session.linesAdded + session.linesRemoved > 0}<span> · <span class="add">+{session.linesAdded}</span> <span class="rem">−{session.linesRemoved}</span></span>{/if}
    </div>
    {#if launcher}
      <button class="launcher" onclick={() => agents.select(launcher.id)}><Ico name="terminal" size={12} />{tr("Gestart door een agent in {title}", "Started by an agent in {title}", { title: launcher.project })}</button>
    {/if}
  </header>

  <div class="scroll">
  <div class="thread-column body">
  {#if approval}<ApprovalCard {approval} />{/if}
  {#if question}{#key question.id}<QuestionCard request={question} />{/key}{/if}
  {#if session.compacting}
    <div class="compacting" role="status">
      <span class="compacting-dot"></span>
      <span>{tr("Het gesprek wordt samengevat…", "Compacting the conversation…")}</span>
    </div>
  {/if}

  {#if session.status === "detected"}
    <p class="muted">
      {#if canNook}
        {tr("Nook ziet dat {name} draait, maar kan niet meekijken. Neem hem over: de oude sessie sluit af en het gesprek gaat hier verder, met goedkeuringen en stoppen vanuit Nook.", "Nook sees that {name} is running, but can't follow along. Take it over: the old session closes and the conversation continues here, with approvals and stopping from Nook.", { name: session.name })}
      {:else}
        {tr("Nook ziet dat {name} draait, maar kan niet meekijken of hem voortzetten. Je kunt de sessie wel beëindigen.", "Nook sees that {name} is running, but can't follow along or continue it. You can still end the session.", { name: session.name })}
      {/if}
    </p>
    <p class="faint small">{session.isLinked ? tr("Sluit {name} en start hem opnieuw, dan volgt Nook hem.", "Close {name} and start it again, then Nook follows it.", { name: session.name }) : tr("Koppel {name} bij Instellingen › Agents zodat Nook nieuwe sessies vanaf de start volgt.", "Link {name} in Settings › Agents so Nook follows new sessions from the start.", { name: session.name })}</p>
  {/if}

    {#if session.transcriptPath}
      <Conversation path={session.transcriptPath} refreshKey={session.updated ?? ""} baseFolder={session.cwd ?? null} />
    {:else}
      <div class="steps">
        {#each session.steps as step, i (i)}
          <div class="step {step.mark}"><span class="mark">{step.mark === "done" ? "✓" : step.mark === "running" ? "◐" : step.mark === "blocked" ? "●" : step.mark === "failed" ? "✗" : "○"}</span>{step.text}</div>
        {/each}
      </div>
      {#if session.lastReply}<p class="reply">{session.lastReply}</p>{/if}
    {/if}
    {#if session.diff.length && session.status !== "done" && session.status !== "failed" && session.transcriptPath}
      <DiffView lines={session.diff} max={220} />
    {/if}
  </div>
  </div>

  <div class="thread-column foot">
  {#if error}<p class="err">{error}</p>{/if}
  <!-- What Nook could do for what was said here, as under a session Nook runs (`ActionSuggestionBar`). -->
  <ActionSuggestionBar turn={session.lastReply.trim() ? { conversation: `session:${session.id}`, message: String(session.lastReply.length) + ":" + session.lastReply.slice(-40), date: session.updated } : null}
    busy={session.status === "running"} place={{ kind: "agent", name: session.name, title: session.project }}
    lines={() => [{ speaker: "You", text: session.lastPrompt, id: `${session.id}:prompt` }, { speaker: session.name, text: session.lastReply, id: `${session.id}:reply` }]} />

  {#if canNook && ontakeover && session.status !== "detected"}
    <div class="reply-box">
      <input
        bind:this={replyInput}
        placeholder={busy ? tr("Stuur een bericht (Nook gaat verder met een kopie)…", "Send a message (Nook continues with a copy)…") : tr("Ga verder met deze sessie in Nook…", "Continue this session in Nook…")}
        bind:value={message}
        onkeydown={(e) => e.key === "Enter" && send()}
      />
      <button class="primary" disabled={!message.trim()} onclick={send}>{tr("Stuur", "Send")}</button>
    </div>
    {#if busy}<p class="faint small">{tr("De sessie is nog bezig: Nook gaat verder met een kopie van het gesprek, zodat ze elkaar niet storen.", "The session is still busy: Nook continues with a copy of the conversation, so they don't get in each other's way.")}</p>{/if}
  {/if}

  <div class="actions">
    {#if session.host && session.status !== "detected"}<button onclick={terminal}>{tr("Open {app}", "Open {app}", { app: terminalName })}</button>{/if}
    {#if canNook && ontakeover}
      <button onclick={() => ontakeover?.(session, true)} disabled={!canEnd}>{tr("Neem over in Nook", "Take over in Nook")}</button>
    {/if}
    <button class="ghost perm-btn" onclick={() => (showPermissions = true)} title={tr("Opgeslagen regels en geschiedenis", "Granted rules and approval log")}>
      <Ico name="shield-check" size={14} />
      {tr("Toestemmingen", "Permissions")}
    </button>
    <span class="spacer"></span>
    {#if canEnd}<button class="ghost danger" onclick={end}>{tr("Beëindig sessie", "End session")}</button>{/if}
  </div>
  </div>
</div>

{#if showPermissions}
  <GrantedRulesSheet project={session.cwd || null} onclose={() => (showPermissions = false)} />
{/if}

<style>
  .detail { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  /* The thread header: the project, a slash and the thread's name, its state on the right. */
  .thread-head { display: flex; align-items: center; gap: 12px; min-height: 52px; padding: 0 16px; flex: none; }
  .thread-head .title { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1; font-size: 14px; }
  .project { color: var(--text2); white-space: nowrap; max-width: 160px; overflow: hidden; text-overflow: ellipsis; flex: none; }
  .slash { color: var(--text3); }
  .name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta { display: flex; align-items: center; gap: 6px; font-size: 12px; white-space: nowrap; }
  .launcher { display: inline-flex; align-items: center; gap: var(--space-4); border: 0; background: none; padding: 0; font: var(--text-label); color: var(--text3); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
  .launcher:hover { color: var(--blue); }
  .body { display: flex; flex-direction: column; gap: 12px; padding-top: 8px; padding-bottom: 16px; }
  .foot { display: flex; flex-direction: column; gap: 8px; padding-bottom: 12px; flex: none; }
  .add { color: var(--mint); }
  .rem { color: var(--coral); }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; }
  .compacting { display: inline-flex; align-items: center; gap: var(--space-8); align-self: flex-start; padding: var(--space-6) var(--space-12); border: 1px solid color-mix(in srgb, var(--blue) 30%, var(--line2)); border-radius: var(--radius-card); background: color-mix(in srgb, var(--blue) 10%, var(--surface)); font: var(--text-detail); color: var(--blue); }
  .compacting-dot { width: 7px; height: 7px; border-radius: 999px; background: var(--blue); box-shadow: 0 0 0 3px color-mix(in srgb, var(--blue) 25%, transparent); }
  .steps { display: flex; flex-direction: column; gap: 4px; font-size: 14px; color: var(--text2); }
  .step .mark { display: inline-block; width: 18px; }
  .step.done .mark { color: var(--mint); }
  .step.running .mark { color: var(--paper); }
  .step.blocked .mark { color: var(--amber); }
  .step.failed .mark { color: var(--coral); }
  .step.todo { color: var(--text3); }
  .reply { white-space: pre-wrap; user-select: text; color: var(--text2); }
  /* The reply field in the composer surface. */
  .reply-box { display: flex; gap: 6px; align-items: center; padding: 6px 6px 6px 14px; border: 1px solid var(--line2); border-radius: var(--radius-composer); background: var(--surface); }
  .reply-box:focus-within { border-color: color-mix(in srgb, var(--paper) 22%, var(--line2)); }
  .reply-box input { flex: 1; border: 0; background: transparent; padding: 6px 0; font-size: 14px; }
  .reply-box input:focus-visible { box-shadow: none; }
  .reply-box button { border-radius: 999px; height: 32px; padding: 0 14px; }
  .actions { display: flex; gap: 6px; align-items: center; }
  .perm-btn { display: inline-flex; align-items: center; gap: var(--space-6); }
  .spacer { flex: 1; }
  .small { font-size: 12px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
