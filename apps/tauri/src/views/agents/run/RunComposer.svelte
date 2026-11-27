<script lang="ts">
  // Het invoerveld van een sessie die Nook draait (de composer in `AgentRunPanel`, met
  // `QueuedMessagesStrip`): je vervolgbericht, of terwijl de agent werkt bijsturen of in de wachtrij; daaronder de
  // keuzes voor de volgende beurt (model, modus, rechten, denkniveau) en ⋯ voor de rest.
  import {
    effortLevels, isActive, modeHelp, workspaceApi, type PermissionPolicy, type RunProvider, type WorkspaceRun,
  } from "../../../lib/workspace/api";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agentApi, type AgentProfile } from "../../../lib/agents";
  import { agents } from "../../../lib/agents.svelte";
  import { automationApi } from "../../../lib/workspace/automation";
  import Ico from "../../../components/ui/Ico.svelte";
  import Dropdown from "../../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../../components/ui/DropdownRow.svelte";
  import MicButton from "../../../components/MicButton.svelte";
  import AgentModelPicker from "./AgentModelPicker.svelte";
  import ComposerContext from "./ComposerContext.svelte";
  import ContextBreakdown from "./ContextBreakdown.svelte";
  import PromptTools from "./PromptTools.svelte";
  import RunBranchTray from "./RunBranchTray.svelte";
  import { composerInbox } from "../../../lib/workspace/composer-inbox.svelte";
  import { merging } from "../../../lib/workspace/session-prompts";
  import { prompts } from "../../../lib/workspace/prompts.svelte";
  import { compose, fileRef, isPicture, project, timeline, type ContextRef } from "../../../lib/workspace/context-refs";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { onCommands } from "../../../lib/commands";
  import { keyFlags } from "../../../lib/key-context";
  import { stashKey } from "../../../lib/workspace/draft-stash";
  import { nook } from "../../../lib/state.svelte";
  import { listening } from "../../../lib/listening.svelte";
  import { oneLine } from "../../../lib/workspace/timeline";
  import { replacingPasted } from "../../../lib/workspace/session-link";
  import { continued as continuedList } from "../../../lib/workspace/composer-lists";

  let { run, onsidechat }: { run: WorkspaceRun; onsidechat?: (question: string) => void } = $props();

  // The parent hands a new `run` object on every workspace update; only another run reloads the draft and takes focus.
  const runId = $derived(run.id);
  const key = $derived(`ws.draft.${runId}`);
  let draft = $state("");
  let editing = $state<string | null>(null);
  let savedDraft = "";
  let profiles = $state<AgentProfile[]>([]);
  let collapsed = $state(false);
  let textarea = $state<HTMLTextAreaElement>();

  $effect(() => {
    try {
      draft = localStorage.getItem(key) ?? "";
    } catch {
      draft = "";
    }
    workspace.loadQueue(runId);
    requestAnimationFrame(() => textarea?.focus());
  });

  $effect(() => {
    try {
      if (draft) localStorage.setItem(key, draft);
      else localStorage.removeItem(key);
    } catch {
      // Geen opslag: het concept blijft alleen zolang de tab open is.
    }
  });

  const active = $derived(isActive(run.status));
  const caps = $derived(workspace.provider(run.provider)?.capabilities);
  const queue = $derived(workspace.queues[run.id]);
  const steerDefault = $derived(workspace.settings?.steerByDefault ?? true);
  const canSteer = $derived(active && !!caps?.steering);
  const steers = $derived(canSteer && steerDefault);
  const short = $derived(run.provider === "claude" ? "Claude" : workspace.provider(run.provider)?.name ?? run.provider);
  const prompt = $derived(active ? (steers ? tr("{agent} is bezig… typ om bij te sturen", "{agent} is working… type to steer", { agent: short }) : tr("{agent} is bezig… typ een vervolg voor de wachtrij", "{agent} is working… type a follow-up for the queue", { agent: short })) : tr("Stuur een vervolgbericht…", "Send a follow-up…"));
  const events = $derived(workspace.timelines[run.id] ?? []);
  /// The agents the picker offers: the ones on this computer, and this session's own in any case.
  const pickable = $derived(workspace.providers.filter((p) => p.supported && (p.executable || p.provider === run.provider)));

  $effect(() => {
    agentApi.profiles().then((p) => (profiles = p)).catch(() => (profiles = []));
  });

  // `/clear` (`FreshConversation` on the Mac) arms the session: your next message starts a new conversation.
  let fresh = $state(false);

  // Files, folders, snippets (PDF points / web elements) and pictures you add, and the `@` / `#` references you typed (`ComposerContext`).
  let attached = $state<ContextRef[]>([]);
  let pictures = $state<string[]>([]);
  let mentions = $state<ContextRef[]>([]);
  let excerpts = $state<Record<string, string>>({});

  // A pasted session link (`nook://session/…`, "Copy session link") becomes that session's mention, the same as picking
  // it after `@` (`SessionLink.replacingPasted` on the Mac).
  function paste(e: ClipboardEvent) {
    const text = e.clipboardData?.getData("text/plain") ?? "";
    if (!text.includes("nook://session/") || !textarea) return;
    const from = textarea.selectionStart ?? draft.length;
    const to = textarea.selectionEnd ?? from;
    const next = draft.slice(0, from) + text + draft.slice(to);
    const replaced = replacingPasted(draft, next);
    if (!replaced) return;
    e.preventDefault();
    const caret = replaced.text.length - (draft.length - to);
    draft = replaced.text;
    const fresh = replaced.refs.filter((r) => !mentions.some((m) => m.kind === r.kind && m.id === r.id));
    if (fresh.length) mentions = [...mentions, ...fresh];
    requestAnimationFrame(() => textarea?.setSelectionRange(caret, caret));
  }
  let context = $state<ReturnType<typeof ComposerContext>>();
  let promptTools = $state<ReturnType<typeof PromptTools>>();

  // What the side panel handed this session (Explain, Ask, Fix, PDF spots): above what you wrote, for you to read and send.
  $effect(() => {
    const waiting = composerInbox.waiting[runId];
    if (!waiting || (!waiting.texts.length && !waiting.snippets.length && !waiting.pictures.length)) return;
    const delivery = composerInbox.takeDelivery(runId);
    for (const block of delivery.texts) draft = merging(block, draft);
    if (delivery.snippets.length) {
      const nextExcerpts = { ...excerpts };
      const nextAttached = [...attached];
      for (const s of delivery.snippets) {
        nextExcerpts[s.ref.id] = s.content;
        if (!nextAttached.some((a) => a.id === s.ref.id)) nextAttached.push(s.ref);
      }
      excerpts = nextExcerpts;
      attached = nextAttached;
    }
    if (delivery.pictures.length) {
      const added = delivery.pictures.filter((p) => !pictures.includes(p));
      if (added.length) pictures = [...pictures, ...added];
    }
    requestAnimationFrame(() => textarea?.focus());
  });
  let listOpen = $state(false);
  const hasAttachments = $derived(attached.length + pictures.length > 0);

  /** Puts an earlier user message back into the composer after "Edit from here" (AG-62). */
  export function loadEdited(text: string) {
    const unpacked = timeline(text, run.workingDirectory);
    editing = null;
    fresh = false;
    mentions = [];
    excerpts = {};
    pictures = unpacked.paths.filter(isPicture);
    attached = unpacked.paths.filter((p) => !isPicture(p)).map(fileRef);
    draft = unpacked.words;
    requestAnimationFrame(() => textarea?.focus());
  }

  /// The message as the agent gets it (`ContextRefs.project`), and the composer emptied for the next one.
  function takeMessage(): string {
    const out = project(compose(draft, attached, mentions), pictures, excerpts);
    draft = "";
    attached = [];
    pictures = [];
    mentions = [];
    excerpts = {};
    return out;
  }

  /** Extracts the question from `/btw <question>` or `/side <question>` (AG-61), or null for other messages. */
  function parseSideChat(text: string): string | null {
    const match = text.match(/^\/(?:btw|side)(?:\s+([\s\S]*))?$/i);
    return match ? (match[1] ?? "").trim() : null;
  }

  const sideDraft = $derived(parseSideChat(draft.trim()));

  async function send() {
    const text = draft.trim();
    if (editing) {
      await saveEdit();
      return;
    }
    if (!text && !hasAttachments) return;
    // `/btw <question>` or `/side <question>` (AG-61): runs as a side chat without interrupting the main agent.
    const sideQuestion = parseSideChat(text);
    if (sideQuestion !== null) {
      if (!sideQuestion) {
        workspace.error = tr("Typ je vraag achter /btw of /side.", "Type your question after /btw or /side.");
        textarea?.focus();
        return;
      }
      workspace.error = null;
      draft = "";
      onsidechat?.(sideQuestion);
      return;
    }
    if (/^\/clear\s*$/i.test(text)) {
      draft = "";
      fresh = true;
      return;
    }
    if (fresh) {
      if (active) {
        workspace.error = tr("/clear wacht tot de agent gestopt is.", "/clear waits until the agent has stopped.");
        return;
      }
      const cleared = await workspace.act(() => workspaceApi.clear(run.id));
      if (!cleared) return;
      fresh = false;
    }
    if (active) {
      deliver(steers ? "steer" : "queue");
      return;
    }
    const message = takeMessage();
    await workspace.act(() => workspaceApi.send(run.id, message));
  }

  async function deliver(intent: "steer" | "queue") {
    if (!draft.trim() && !hasAttachments) return;
    const text = takeMessage();
    if (intent === "steer" && canSteer) await workspace.act(() => workspaceApi.steer(run.id, text));
    else await workspace.act(() => workspaceApi.enqueue(run.id, text));
    workspace.loadQueue(run.id);
  }

  // The `/` list (`AgentCommands`): only commands this agent really has. Nook's own (plan, clear, fork, goal, btw, side),
  // Claude Code's and Codex's built-in compact, then what the agent announced itself (ACP `available_commands_update`).
  type Command = { name: string; detail: string; insertion: string | null; run?: () => void };
  let offered = $state<{ name: string; detail: string; takesInput: boolean }[]>([]);
  let commandIndex = $state(0);
  $effect(() => {
    void runId;
    void run.status;
    workspaceApi.agentCommands(runId).then((c) => (offered = c)).catch(() => (offered = []));
  });
  const builtIn = (p: string) => p === "claude" || p === "codex";
  const canCompact = $derived(builtIn(run.provider) || offered.some((c) => c.name === "compact"));
  const commands = $derived.by((): Command[] => {
    const list: Command[] = [];
    if (caps?.planMode) list.push({ name: "plan", detail: tr("Naar Plan-modus", "Switch to Plan mode"), insertion: null, run: () => workspace.act(() => workspaceApi.configure(run.id, { mode: "plan" })) });
    list.push({ name: "clear", detail: tr("Je volgende bericht begint een nieuw gesprek: de agent vergeet dit gesprek", "Your next message starts a new conversation: the agent forgets this one"), insertion: null, run: () => (fresh = true) });
    if (!active) list.push({ name: "fork", detail: tr("Een vork van deze sessie maken", "Fork this session"), insertion: null, run: () => fork() });
    if (builtIn(run.provider)) {
      list.push({ name: "compact", detail: tr("Het gesprek samenvatten om ruimte te maken", "Summarize the conversation to free up space"), insertion: "/compact" });
    }
    list.push({ name: "goal", detail: tr("Een doel instellen waar de agent naartoe werkt", "Set a goal the agent works toward"), insertion: "/goal " });
    list.push({ name: "btw", detail: tr("Stel een snelle zijvraag zonder de agent te onderbreken", "Ask a quick side question without interrupting the agent"), insertion: "/btw " });
    list.push({ name: "side", detail: tr("Stel een snelle zijvraag zonder de agent te onderbreken", "Ask a quick side question without interrupting the agent"), insertion: "/side " });
    for (const c of offered) {
      if (!list.some((x) => x.name === c.name)) list.push({ name: c.name, detail: c.detail, insertion: `/${c.name}${c.takesInput ? " " : ""}` });
    }
    // Your saved prompts with a trigger (`/summarize`), after the agent's own.
    for (const p of prompts.list) {
      if (p.trigger && !list.some((x) => x.name === p.trigger)) list.push({ name: p.trigger, detail: p.title, insertion: null, run: () => promptTools?.use(p) });
    }
    return list;
  });
  const typedCommand = $derived(/^\/[^\s]*$/.test(draft) && !editing ? draft.slice(1).toLowerCase() : null);
  // A command already written out in full ("/compact") is sent with Return, not picked again.
  const matching = $derived(typedCommand === null || commands.some((c) => c.insertion === draft) ? [] : commands.filter((c) => c.name.startsWith(typedCommand)));

  /// `/fork`: a new session from this one, opened at once.
  async function fork() {
    const id = await workspace.act(() => workspaceApi.fork(run.id));
    if (id) agents.select(`run:${id}`);
  }

  function pickCommand(c: Command) {
    commandIndex = 0;
    if (c.insertion === null) {
      draft = "";
      c.run?.();
    } else {
      draft = c.insertion;
    }
    textarea?.focus();
  }

  // Next-prompt ghost suggestion (`NextPromptSuggestion` on macOS, AG-70): shown in the empty composer after an assistant turn;
  // Tab accepts it into `draft`, Escape dismisses it.
  let suggestedPrompt = $state<string | null>(null);
  let dismissedTurnId = $state<string | null>(null);
  let lastSuggestedTurnKey = "";

  const lastAssistantTurnKey = $derived.by(() => {
    if (active) return "";
    const visible = events.filter((e) => !e.rolledBack && (e.kind === "user" || e.kind === "assistant") && e.text.trim());
    const last = visible[visible.length - 1];
    if (!last || last.kind !== "assistant" || !visible.some((e) => e.kind === "user")) return "";
    return `${runId}:${last.id}`;
  });

  $effect(() => {
    const turnKey = lastAssistantTurnKey;
    if (!turnKey || turnKey === dismissedTurnId) {
      suggestedPrompt = null;
      return;
    }
    try {
      if (localStorage.getItem("nook.suggestNextPrompt") === "false") {
        suggestedPrompt = null;
        return;
      }
    } catch {
      // default enabled
    }
    if (turnKey === lastSuggestedTurnKey) return;
    lastSuggestedTurnKey = turnKey;
    suggestedPrompt = null;
    let cancelled = false;
    import("@tauri-apps/api/core")
      .then(({ invoke }) => invoke<string | null>("workspace_suggest_next_prompt", { run: runId }))
      .then((res) => {
        if (!cancelled && lastAssistantTurnKey === turnKey) {
          suggestedPrompt = res?.trim() || null;
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  });

  const ghostSuggestion = $derived(
    !active && !editing && !draft && !hasAttachments && suggestedPrompt && lastAssistantTurnKey !== dismissedTurnId
      ? suggestedPrompt
      : null,
  );

  function keydown(e: KeyboardEvent) {
    if (context?.key(e)) return;
    if (matching.length) {
      if (e.key === "ArrowDown") { e.preventDefault(); commandIndex = (commandIndex + 1) % matching.length; return; }
      if (e.key === "ArrowUp") { e.preventDefault(); commandIndex = (commandIndex - 1 + matching.length) % matching.length; return; }
      if ((e.key === "Enter" && !e.shiftKey) || e.key === "Tab") { e.preventDefault(); pickCommand(matching[Math.min(commandIndex, matching.length - 1)]); return; }
      if (e.key === "Escape") { e.preventDefault(); draft = ""; return; }
    }
    if (ghostSuggestion) {
      if (e.key === "Tab" && !e.shiftKey) {
        e.preventDefault();
        draft = ghostSuggestion;
        suggestedPrompt = null;
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        dismissedTurnId = lastAssistantTurnKey;
        suggestedPrompt = null;
        return;
      }
    }
    // Ctrl+Enter, Ctrl+Shift+Enter and Ctrl+. are rules (`composer.send`, `composer.sendAlternate`, `queue.steerFirst`,
    // `session.interrupt`) the shell resolves, so a rebound key works; the commands are below.
    if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      send();
    } else if (e.key === "Escape" && editing) {
      cancelEdit();
    }
  }

  // What the shell's key rules ask of this composer (`SessionComposer.baseKeyHandlers` on the Mac).
  $effect(() => {
    keyFlags.turnRunning = active;
    keyFlags.composerDraft = !!draft.trim();
    return () => { keyFlags.turnRunning = false; keyFlags.composerDraft = false; };
  });
  const sent = $derived(events.filter((e) => e.kind === "user").map((e) => timeline(e.text ?? "", run.workingDirectory).words).filter((w) => w.trim()));
  let walking = -1;
  function walkHistory(delta: number): boolean {
    if (!sent.length || editing) return false;
    const next = walking < 0 ? (delta < 0 ? sent.length - 1 : -1) : walking + delta;
    if (next < 0 || next >= sent.length) { walking = -1; if (delta > 0) draft = ""; return delta > 0 || walking === -1; }
    walking = next;
    draft = sent[next];
    return true;
  }
  const access: PermissionPolicy[] = ["ask", "acceptEdits", "bypass"];
  function stepEffort(delta: number): boolean {
    const levels = effortLevels(run.provider);
    if (!levels.length || !caps) return false;
    const at = run.effort ? levels.indexOf(run.effort) : -1;
    const next = Math.min(levels.length - 1, Math.max(0, at + delta));
    if (next !== at) setEffort(levels[next]);
    return true;
  }
  $effect(() => onCommands({
    "composer.send": () => {
      if (active || (!draft.trim() && !hasAttachments)) return false;
      send();
    },
    "composer.sendAlternate": () => {
      if (!active || !draft.trim() || sideDraft !== null) return false;
      deliver(steers ? "queue" : "steer");
    },
    "queue.steerFirst": () => {
      const first = queue?.messages[0];
      if (!active || !first || !canSteer) return false;
      queueAction(() => workspaceApi.queueSteer(run.id, first.id));
    },
    "session.interrupt": () => {
      if (!active) return false;
      workspace.act(() => workspaceApi.stop(run.id));
    },
    "composer.stash": () => { draft = stashKey(draft); textarea?.focus(); },
    "composer.pasteAsText": () => {
      navigator.clipboard.readText().then((text) => {
        const at = textarea?.selectionStart ?? draft.length;
        const to = textarea?.selectionEnd ?? at;
        draft = draft.slice(0, at) + text + draft.slice(to);
      }).catch(() => {});
    },
    "composer.startInBackground": () => {
      if (editing || (!draft.trim() && !hasAttachments)) return false;
      (active ? deliver(steers ? "steer" : "queue") : send()).then(() => agents.select("new"));
    },
    "composer.historyPrevious": () => walkHistory(-1),
    "composer.historyNext": () => walkHistory(1),
    "composer.access": () => {
      const at = access.indexOf(run.permission);
      setPermission(access[(at + 1) % access.length]);
    },
    "composer.dictate": () => { if (!nook.info?.capabilities.microphone) return false; listening.toggle(); },
    "effort.increase": () => stepEffort(1),
    "effort.decrease": () => stepEffort(-1),
  }));

  function beginEdit(id: string, text: string) {
    if (!editing) savedDraft = draft;
    editing = id;
    draft = text;
    textarea?.focus();
  }

  async function saveEdit() {
    const id = editing;
    if (!id) return;
    const text = draft.trim();
    editing = null;
    draft = savedDraft;
    if (text) await workspace.act(() => workspaceApi.queueEdit(run.id, id, text));
    workspace.loadQueue(run.id);
  }

  function cancelEdit() {
    editing = null;
    draft = savedDraft;
  }

  async function queueAction(f: () => Promise<unknown>) {
    await workspace.act(f);
    workspace.loadQueue(run.id);
  }

  function setPermission(p: PermissionPolicy) {
    workspace.act(() => workspaceApi.configure(run.id, { permission: p }));
  }

  function setEffort(level: string | null) {
    workspace.act(() => workspaceApi.configure(run.id, { effort: level }));
  }

  /// A model of this agent applies from the next turn; another agent or account takes the session over with what
  /// happened so far (`workspace_hand_off`, the Mac's `applySelection`), shown in the timeline.
  async function choose(provider: RunProvider, profileId: string, model: string) {
    if (provider === run.provider && profileId === run.profileId) {
      if (model !== run.model) workspace.act(() => workspaceApi.configure(run.id, { model }));
      return;
    }
    const id = run.id;
    await workspace.act(async () => {
      // Picked while the agent works (`compose.switchWhileBusy`): this turn stops first, then the other agent takes over.
      if (isActive(run.status)) {
        await workspaceApi.stop(id);
        for (let i = 0; i < 60 && isActive(workspace.run(id)?.status ?? "stopped"); i++) {
          await new Promise((r) => setTimeout(r, 250));
          await workspace.refresh();
        }
      }
      await automationApi.handOff(id, provider, profileId, model);
      await workspace.loadTimeline(id);
    });
  }

  /// "+ Add a file or folder": its path goes into the message, where the agent reads it (`ComposerAttachments`).
  async function attachFile() {
    try {
      const picked = await openDialog({ multiple: true, defaultPath: run.workingDirectory || undefined, title: tr("Bestand of map toevoegen", "Add a file or folder") });
      for (const path of Array.isArray(picked) ? picked : picked ? [picked] : []) context?.addPath(path);
      textarea?.focus();
    } catch (e) {
      workspace.error = String(e);
    }
  }

  // Markdown lists keep going (`ComposerLists`): a new line after "- item" or "7." starts the next item; one after an
  // empty item ends the list.
  function listInput(e: Event) {
    const field = e.currentTarget as HTMLTextAreaElement;
    if ((e as InputEvent).inputType !== "insertLineBreak" && !((e as InputEvent).inputType === "insertText" && (e as InputEvent).data === "\n")) return;
    const next = continuedList(field.value, field.selectionStart ?? field.value.length);
    if (!next) return;
    draft = next.text;
    field.value = next.text;
    field.setSelectionRange(next.caret, next.caret);
  }
</script>


<div class="composer">
  <RunBranchTray runId={run.id} directory={run.workingDirectory} branch={run.branch} />
  {#if queue && queue.messages.length}
    <div class="queue">
      <button class="qhead" onclick={() => (collapsed = !collapsed)}>
        <span class="chev" class:open={!collapsed}>›</span> {tr("In de wachtrij ({n})", "Queued ({n})", { n: queue.messages.length })}
      </button>
      {#if !collapsed}
        {#each queue.messages as m, i (m.id)}
          <div class="qrow">
            <span class="faint">{editing === m.id ? "✎" : "◷"}</span>
            <span class="qtext">{oneLine(timeline(m.text).words || m.text, 120)}</span>
            {#if queue.messages.length > 1}
              <button class="icon" title={tr("Omhoog", "Up")} disabled={i === 0} onclick={() => queueAction(() => workspaceApi.queueMove(run.id, m.id, i - 1))}>↑</button>
              <button class="icon" title={tr("Omlaag", "Down")} disabled={i === queue.messages.length - 1} onclick={() => queueAction(() => workspaceApi.queueMove(run.id, m.id, i + 1))}>↓</button>
            {/if}
            <button class="icon" title={tr("Bewerken", "Edit")} disabled={editing === m.id} onclick={() => beginEdit(m.id, m.text)}>✎</button>
            {#if canSteer}<button class="icon" title={tr("Nu bijsturen", "Steer now")} disabled={editing === m.id} onclick={() => queueAction(() => workspaceApi.queueSteer(run.id, m.id))}>↳</button>{/if}
            <button class="icon" title={tr("Uit de wachtrij halen", "Remove from queue")} onclick={() => { if (editing === m.id) cancelEdit(); queueAction(() => workspaceApi.queueRemove(run.id, m.id)); }}>✕</button>
          </div>
        {/each}
        <div class="qnote">
          <span class="faint">{queue.isHeld ? tr("De wachtrij is gepauzeerd na een fout of stop. Verstuur zelf of kies Nu versturen.", "The queue is paused after an error or stop. Send yourself or choose Send now.") : tr("Gaat vanzelf zodra de agent klaar is. Na een fout of stop wacht de rij op jou.", "Goes out on its own once the agent is done. After an error or stop the queue waits for you.")}</span>
          {#if !active}<button class="ghost" onclick={() => queueAction(() => workspaceApi.queueSendNow(run.id))}>{tr("Nu versturen", "Send now")}</button>{/if}
        </div>
      {/if}
    </div>
  {/if}

  <!-- The session's composer (`SessionComposer`): the message on top; under it "+", the agent pill (model, mode, access
       and effort in its picker, as on the Mac), the microphone, and send or stop. The session's own actions are in the
       menu beside its name in the header. -->
  <PromptTools bind:this={promptTools} bind:draft {textarea} />
  {#if fresh}
    <!-- The strip above the composer while /clear waits for your next message (`ws.fresh.title`). -->
    <div class="fresh">
      <Ico name="message-square" size={15} />
      <span class="fresh-text"><strong>{tr("Je volgende bericht begint een nieuw gesprek", "Your next message starts a new conversation")}</strong>
        <span>{tr("De agent ziet de eerdere berichten niet. De tijdlijn bewaart ze.", "The agent won't see the earlier messages. The timeline keeps them.")}</span></span>
      <button class="ghost" onclick={() => (fresh = false)}>{tr("Dit gesprek houden", "Keep this conversation")}</button>
    </div>
  {/if}
  <div class="box">
    {#if matching.length}
      <!-- The command list over the composer (`ComposerRich`'s commands): name and what it does. -->
      <div class="commands" role="listbox" aria-label={tr("Opdrachten", "Commands")}>
        {#each matching as c, i (c.name)}
          <button role="option" aria-selected={i === commandIndex} class:lit={i === commandIndex} onmousedown={(e) => { e.preventDefault(); pickCommand(c); }}>
            <span class="cname">/{c.name}</span><span class="cdetail">{c.detail}</span>
          </button>
        {/each}
      </div>
    {/if}
    <ComposerContext bind:this={context} {textarea} bind:draft root={run.workingDirectory || null} bind:attached bind:pictures bind:mentions exclude={run.id} bind:open={listOpen} />
    <div class="input-wrap">
      <textarea bind:this={textarea} bind:value={draft} placeholder={ghostSuggestion ? "" : editing ? tr("Bewerk het bericht in de wachtrij (Enter bewaart, Esc annuleert)", "Edit the queued message (Enter saves, Esc cancels)") : prompt} rows="1" onkeydown={keydown} onpaste={paste} oninput={listInput}></textarea>
      {#if ghostSuggestion}
        <button
          type="button"
          class="ghost-suggestion"
          tabindex="-1"
          title={tr("Druk op Tab om over te nemen of Esc om te verbergen", "Press Tab to accept or Esc to dismiss")}
          onclick={() => { draft = ghostSuggestion; suggestedPrompt = null; textarea?.focus(); }}>
          <span class="ghost-text">{ghostSuggestion}</span>
          <kbd class="ghost-kbd">Tab</kbd>
        </button>
      {/if}
    </div>
    <div class="bar">
      <Dropdown width={260} label={tr("Meer opties", "More options")}>
        {#snippet trigger({ toggle, open })}
          <button class="plus" class:lit={open} onclick={toggle} title={tr("Meer opties", "More options")} aria-label={tr("Meer opties", "More options")} aria-expanded={open}><Ico name="plus" size={14} stroke={2.4} /></button>
        {/snippet}
        {#snippet children({ close })}
          <DropdownRow symbol="paperclip" title={tr("Bestand of map toevoegen", "Add a file or folder")} onclick={() => { close(); attachFile(); }} />
          <!-- The prompt library (`PromptLibrary`): keep what you typed, or use a saved prompt. -->
          <DropdownRow symbol="bookmark" title={tr("Bewaar als prompt…", "Save as prompt…")} disabledReason={draft.trim() ? undefined : tr("Typ eerst wat je wilt bewaren.", "Type what you want to keep first.")} onclick={() => { close(); promptTools?.openSave(); }} />
          {#if prompts.list.length}
            <div class="dd-header">{tr("Prompts", "Prompts")}</div>
            {#each prompts.list.slice(0, 8) as p (p.id)}
              <DropdownRow symbol="message-square-text" title={p.title} trailing={p.trigger ? `/${p.trigger}` : undefined} onclick={() => { close(); promptTools?.use(p); }} />
            {/each}
          {/if}
        {/snippet}
      </Dropdown>
      <AgentModelPicker providers={pickable} {profiles} provider={run.provider} profileId={run.profileId} model={run.model}
        mode={run.mode} permission={run.permission} effort={run.effort}
        title={run.resolvedModel ?? undefined}
        note={active ? tr("De agent is bezig: een ander account of andere agent stopt eerst deze beurt, draagt de context over en gaat daar dan verder.", "The agent is working: another account or agent stops this turn first, hands over the context and then continues there.") : undefined}
        onchoose={choose}
        onmode={(m) => workspace.act(() => workspaceApi.configure(run.id, { mode: m }))}
        onpermission={setPermission}
        oneffort={setEffort} />
      {#if run.mode === "plan"}
        <!-- Plan mode stays in sight as its own pill (`ModeToggle`), a click back to Agent. -->
        <span class="divider"></span>
        <button class="pill" disabled={active} title={modeHelp.plan} onclick={() => workspace.act(() => workspaceApi.configure(run.id, { mode: "agent" }))}><Ico name="list-checks" size={15} /><span>{tr("Plan", "Plan")}</span></button>
      {/if}
      <span class="spacer"></span>
      <ContextBreakdown {run} {events} {canCompact} />
      {#if active && draft.trim()}
        {#if sideDraft !== null}
          <button class="pill" onclick={send} title={tr("Stel een snelle zijvraag zonder de agent te onderbreken", "Ask a quick side question without interrupting the agent")}>{tr("Zijgesprek", "Side chat")}</button>
        {:else}
          <button class="pill" onclick={() => deliver(steers ? "steer" : "queue")} title={steers ? tr("Bijsturen: gaat nu naar de agent", "Steer: goes to the agent now") : tr("In de wachtrij: gaat na deze beurt", "Queue: goes after this turn")}>{steers ? tr("Bijsturen", "Steer") : tr("In de wachtrij", "Queue")}</button>
        {/if}
      {/if}
      <MicButton size={15} />
      {#if active}
        <button class="round stop" title={tr("Stop de agent (Ctrl+.)", "Stop the agent (Ctrl+.)")} aria-label={tr("Stop de agent", "Stop the agent")} onclick={() => workspace.act(() => workspaceApi.stop(run.id))}><Ico name="square" size={12} fill="currentColor" /></button>
      {:else if editing}
        <button class="primary save" disabled={!draft.trim()} title={tr("Bewaar het bericht in de wachtrij", "Save the queued message")} onclick={send}>{tr("Bewaar", "Save")}</button>
      {:else}
        <button class="round send" disabled={!draft.trim() && !hasAttachments} title={tr("Stuur je bericht. De agent gaat verder in dezelfde sessie.", "Send your message. The agent continues in the same session.")} aria-label={tr("Stuur", "Send")} onclick={send}><Ico name="arrow-up" size={14} stroke={2.6} /></button>
      {/if}
    </div>
  </div>
  {#if !active && run.mode === "plan"}
    <p class="hint faint">{tr("Planmodus: de agent maakt alleen een plan. Zet de modus op Agent om het uit te laten voeren.", "Plan mode: the agent only makes a plan. Switch the mode to Agent to have it carried out.")}</p>
  {/if}
  {#if workspace.error}<p class="err">{workspace.error}</p>{/if}
</div>

<style>
  .composer { display: flex; flex-direction: column; gap: 6px; }
  .queue { display: flex; flex-direction: column; gap: 4px; padding: 6px 12px; border-radius: var(--radius-card); background: var(--surface); border: 1px solid var(--line); font-size: 12px; }
  .qhead { background: none; border: none; padding: 0; text-align: left; color: var(--text2); font-size: 12px; }
  .qhead:hover { background: none; color: var(--paper); }
  .chev { display: inline-block; transition: transform 0.15s; }
  .chev.open { transform: rotate(90deg); }
  .qrow { display: flex; gap: 8px; align-items: center; }
  .qtext { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .icon { background: none; border: none; padding: 0 3px; font-size: 11px; color: var(--text2); }
  .qnote { display: flex; gap: 8px; align-items: center; justify-content: space-between; font-size: 11.5px; }
  /* The Mac's `SessionComposer` box: 16 pt in on the left and top, 8 pt at the right and bottom so the round button's
     circle runs parallel to the corner; a hairline that the accent lights a little on focus, a faint light on top. */
  .box { border: 1px solid var(--field-stroke); border-radius: var(--radius-composer); background: var(--composer); padding: var(--space-16) var(--space-8) var(--space-8) var(--space-16); display: flex; flex-direction: column; gap: var(--space-8); box-shadow: inset 0 1px 0 color-mix(in srgb, var(--paper) 6%, transparent); transition: border-color var(--motion-reveal); }
  .box { position: relative; }
  .commands { position: absolute; left: 0; right: 0; bottom: calc(100% + var(--space-6)); z-index: 30; display: flex; flex-direction: column; padding: var(--space-4); background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-card); box-shadow: var(--shadow-popover); max-height: 260px; overflow-y: auto; }
  .commands button { display: flex; align-items: baseline; gap: var(--space-12); margin: 0; padding: var(--space-6) var(--space-8); border: 0; border-radius: var(--radius-chip); background: transparent; text-align: left; }
  .commands button.lit, .commands button:hover { background: var(--smoke); }
  .cname { font: var(--text-body); color: var(--paper); font-family: var(--mono); }
  .cdetail { font: var(--text-detail); color: var(--text3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .box:focus-within { border-color: color-mix(in srgb, var(--iris) 28%, var(--composer)); }
  .input-wrap { position: relative; display: flex; flex-direction: column; }
  textarea { background: transparent; border: none; resize: none; padding: 0; min-height: 20px; max-height: 200px; font: var(--text-body); line-height: 20px; color: var(--paper); field-sizing: content; width: 100%; }
  textarea::placeholder { color: var(--text3); }
  textarea:focus, textarea:focus-visible { border: none; outline: none; box-shadow: none; }
  .ghost-suggestion { position: absolute; inset: 0; display: flex; align-items: center; gap: var(--space-8); margin: 0; padding: 0 var(--space-8) 0 0; border: 0; background: transparent; font: var(--text-body); line-height: 20px; color: var(--text3); text-align: left; pointer-events: auto; cursor: text; overflow: hidden; }
  .ghost-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: 0.72; }
  .ghost-kbd { flex: none; padding: 1px 5px; border-radius: var(--radius-chip); border: 1px solid var(--line2); background: var(--surface); font: var(--text-label); font-family: var(--mono); line-height: 15px; color: var(--text2); }
  .bar { display: flex; align-items: center; gap: var(--space-4); margin-left: calc(-1 * var(--space-8)); min-width: 0; }
  .bar :global(.mic) { width: 28px; height: 28px; color: var(--text2); }
  /* The plus as the Mac's `ComposerIcon`: a 26 pt square, quiet until hovered. */
  .plus { display: grid; place-items: center; width: 26px; height: 26px; flex: none; padding: 0; margin: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .plus:hover, .plus.lit { background: var(--smoke); color: var(--paper); }
  .pill { display: inline-flex; align-items: center; gap: var(--space-6); height: 28px; padding: 0 var(--space-8); margin: 0; border: 0; border-radius: var(--radius-control); background: none; font: var(--text-control); color: var(--text2); white-space: nowrap; }
  .pill:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  /* `ComposerDivider`: a gap, not a line. */
  .divider { width: var(--space-4); height: 16px; flex: none; }
  .spacer { flex: 1; }
  /* Send and stop: 32 pt circles, the accent when they can act, smoke dimmed by half when not. */
  .round { display: grid; place-items: center; width: 32px; height: 32px; padding: 0; margin: 0; border: 0; border-radius: 50%; flex: none; background: var(--iris); color: var(--on-iris); }
  .round:hover:not(:disabled) { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }
  .round:disabled { background: var(--smoke); color: var(--text3); opacity: 0.5; }
  .save { height: 32px; padding: 0 var(--space-12); border-radius: 999px; }
  .hint { font: var(--text-caption); margin: 0; }
  .fresh { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-8) var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-card); background: var(--surface); color: var(--text3); }
  .fresh-text { flex: 1; display: flex; flex-direction: column; gap: var(--space-2); font: var(--text-detail); color: var(--text3); }
  .fresh-text strong { font: var(--text-control); color: var(--paper); }
  .err { color: var(--coral); font: var(--text-detail); margin: 0; }
</style>
