<script lang="ts">
  // Het invoerveld van een sessie die Nook draait (de composer in `AgentRunPanel`, met
  // `QueuedMessagesStrip`): je vervolgbericht, of terwijl de agent werkt bijsturen of in de wachtrij; daaronder de
  // keuzes voor de volgende beurt (model, modus, rechten, denkniveau) en ⋯ voor de rest.
  import {
    effortLabels, effortLevels, isActive, modeHelp, permissionHelp, permissionLabels, workspaceApi,
    type PermissionPolicy, type WorkspaceRun,
  } from "../../../lib/workspace/api";
  import Icon from "../../../components/Icon.svelte";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { contextLevel, contextPercent, oneLine } from "../../../lib/workspace/timeline";

  let {
    run,
    onrename,
    ondelete,
    onchanges,
  }: { run: WorkspaceRun; onrename: () => void; ondelete: () => void; onchanges: () => void } = $props();

  // The parent hands a new `run` object on every workspace update; only another run reloads the draft and takes focus.
  const runId = $derived(run.id);
  const key = $derived(`ws.draft.${runId}`);
  let draft = $state("");
  let editing = $state<string | null>(null);
  let savedDraft = "";
  let menu = $state<"" | "more" | "permission" | "effort" | "model">("");
  let modelDraft = $state("");
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
  const fraction = $derived(run.usage.contextWindow && run.usage.contextTokens ? run.usage.contextTokens / run.usage.contextWindow : null);
  const levels = $derived(effortLevels(run.provider));

  async function send() {
    const text = draft.trim();
    if (editing) {
      await saveEdit();
      return;
    }
    if (!text) return;
    if (active) {
      deliver(steers ? "steer" : "queue");
      return;
    }
    draft = "";
    await workspace.act(() => workspaceApi.send(run.id, text));
  }

  async function deliver(intent: "steer" | "queue") {
    const text = draft.trim();
    if (!text) return;
    draft = "";
    if (intent === "steer" && canSteer) await workspace.act(() => workspaceApi.steer(run.id, text));
    else await workspace.act(() => workspaceApi.enqueue(run.id, text));
    workspace.loadQueue(run.id);
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      // Ctrl+Enter doet het andere: in de wachtrij in plaats van bijsturen, of andersom.
      if (active && (e.ctrlKey || e.metaKey)) deliver(steers ? "queue" : "steer");
      else send();
    } else if (e.key === "Escape" && editing) {
      cancelEdit();
    } else if (e.key === "." && (e.ctrlKey || e.metaKey) && active) {
      e.preventDefault();
      workspace.act(() => workspaceApi.stop(run.id));
    }
  }

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
    menu = "";
    workspace.act(() => workspaceApi.configure(run.id, { permission: p }));
  }

  function setEffort(level: string | null) {
    menu = "";
    workspace.act(() => workspaceApi.configure(run.id, { effort: level }));
  }

  function saveModel() {
    menu = "";
    workspace.act(() => workspaceApi.configure(run.id, { model: modelDraft.trim() }));
  }
</script>

<svelte:window onclick={() => (menu = "")} />

<div class="composer">
  {#if queue && queue.messages.length}
    <div class="queue">
      <button class="qhead" onclick={() => (collapsed = !collapsed)}>
        <span class="chev" class:open={!collapsed}>›</span> {tr("In de wachtrij ({n})", "Queued ({n})", { n: queue.messages.length })}
      </button>
      {#if !collapsed}
        {#each queue.messages as m, i (m.id)}
          <div class="qrow">
            <span class="faint">{editing === m.id ? "✎" : "◷"}</span>
            <span class="qtext">{oneLine(m.text, 120)}</span>
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

  <div class="box">
    <textarea bind:this={textarea} bind:value={draft} placeholder={editing ? tr("Bewerk het bericht in de wachtrij (Enter bewaart, Esc annuleert)", "Edit the queued message (Enter saves, Esc cancels)") : prompt} rows="2" onkeydown={keydown}></textarea>
    <div class="bar">
      <div class="pop">
        <button class="pill" title={tr("Instellingen en acties", "Settings and actions")} onclick={(e) => { e.stopPropagation(); menu = menu === "more" ? "" : "more"; }}>⋯</button>
        {#if menu === "more"}
          <div class="menu" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
            {#if active}
              <button onclick={() => { menu = ""; workspace.act(() => workspaceApi.stop(run.id)); }}>{tr("Stop", "Stop")}</button>
            {:else if run.status === "failed" || run.status === "stopped"}
              <button onclick={() => { menu = ""; workspace.act(() => workspaceApi.retry(run.id)); }}>{tr("Opnieuw", "Retry")}</button>
            {/if}
            <button onclick={() => { menu = ""; onrename(); }}>{tr("Wijzig naam", "Rename")}</button>
            <button disabled={!run.repoRoot} onclick={() => { menu = ""; onchanges(); }}>{tr("Wijzigingen bekijken", "View changes")}</button>
            <hr />
            <button disabled={active} onclick={() => { menu = ""; workspace.act(() => workspaceApi.archive(run.id, !run.archived)); }}>{run.archived ? tr("Haal uit archief", "Unarchive") : tr("Archiveer", "Archive")}</button>
            <button class="danger" disabled={active} onclick={() => { menu = ""; ondelete(); }}>{tr("Verwijder", "Delete")}</button>
          </div>
        {/if}
      </div>
      <div class="pop">
        <button class="pill" disabled={active} title={run.resolvedModel ?? tr("Model", "Model")} onclick={(e) => { e.stopPropagation(); modelDraft = run.model; menu = menu === "model" ? "" : "model"; }}>
          <span class="adot" style:background={workspace.provider(run.provider) ? undefined : "var(--text3)"}></span>
          {workspace.provider(run.provider)?.name ?? run.provider}{run.model ? ` · ${run.model}` : ""}
        </button>
        {#if menu === "model"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
            <div class="mhead">{tr("Model voor de volgende beurt", "Model for the next turn")}</div>
            <input bind:value={modelDraft} placeholder={tr("standaard", "default")} onkeydown={(e) => e.key === "Enter" && saveModel()} />
            <div class="mrow"><span class="faint">{tr("Leeg: de standaard van de agent.", "Empty: the agent's default.")}{#if run.resolvedModel} {tr("Nu: {model}.", "Now: {model}.", { model: run.resolvedModel })}{/if}</span><button class="primary" onclick={saveModel}>{tr("Bewaar", "Save")}</button></div>
          </div>
        {/if}
      </div>
      <span class="sep"></span>
      <button class="pill" disabled={active} title={modeHelp[run.mode] + " " + tr("(klik om te wisselen tussen Agent en Plan)", "(click to switch between Agent and Plan)")}
        onclick={() => workspace.act(() => workspaceApi.configure(run.id, { mode: run.mode === "plan" ? "agent" : "plan" }))}>
        {run.mode === "plan" ? tr("Plan", "Plan") : tr("Agent", "Agent")}
      </button>
      <span class="sep"></span>
      <div class="pop">
        <button class="pill" class:hot={run.permission === "bypass" && run.mode !== "plan"} disabled={active || run.mode === "plan"}
          title={permissionHelp(run.permission, run.provider)} onclick={(e) => { e.stopPropagation(); menu = menu === "permission" ? "" : "permission"; }}>
          {run.permission === "bypass" ? "🔓" : "🔒"} {run.mode === "plan" ? tr("Alleen lezen", "Read only") : permissionLabels[run.permission]}
        </button>
        {#if menu === "permission"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
            <div class="mhead">{tr("Toegang", "Access")}</div>
            {#each caps?.policies ?? [] as p (p)}
              <button class="opt" class:chosen={run.permission === p} onclick={() => setPermission(p)}>
                <span class:hot={p === "bypass"}>{permissionLabels[p]}</span>
                <span class="faint small">{permissionHelp(p, run.provider)}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>
      {#if levels.length}
        <span class="sep"></span>
        <div class="pop">
          <button class="pill" disabled={active} title={tr("Hoe diep de agent nadenkt, vanaf de volgende beurt", "How deeply the agent thinks, from the next turn")} onclick={(e) => { e.stopPropagation(); menu = menu === "effort" ? "" : "effort"; }}>
            {effortLabels[run.effort ?? ""]}
          </button>
          {#if menu === "effort"}
            <div class="menu" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
              <button class:chosen={!run.effort} onclick={() => setEffort(null)}>{effortLabels[""]}</button>
              {#each levels as l (l)}<button class:chosen={run.effort === l} onclick={() => setEffort(l)}>{effortLabels[l] ?? l}</button>{/each}
            </div>
          {/if}
        </div>
      {/if}
      <span class="spacer"></span>
      {#if fraction !== null && fraction > 0}
        <span class="ctx {contextLevel(fraction)}" title={tr("Hoe vol het contextvenster zat bij de laatste modelaanroep", "How full the context window was at the last model call")}>ctx {contextPercent(fraction)}</span>
      {/if}
      {#if active}
        {#if draft.trim()}
          <button class="pill" onclick={() => deliver(steers ? "steer" : "queue")} title={steers ? tr("Bijsturen: gaat nu naar de agent", "Steer: goes to the agent now") : tr("In de wachtrij: gaat na deze beurt", "Queue: goes after this turn")}>{steers ? tr("Bijsturen", "Steer") : tr("In de wachtrij", "Queue")}</button>
        {/if}
        <button class="round stop" title={tr("Stop de agent (Ctrl+.)", "Stop the agent (Ctrl+.)")} aria-label={tr("Stop de agent", "Stop the agent")} onclick={() => workspace.act(() => workspaceApi.stop(run.id))}><Icon name="stop" size={12} /></button>
      {:else if editing}
        <button class="primary send" disabled={!draft.trim()} title={tr("Bewaar het bericht in de wachtrij", "Save the queued message")} onclick={send}>{tr("Bewaar", "Save")}</button>
      {:else}
        <button class="primary round" disabled={!draft.trim()} title={tr("Stuur je bericht. De agent gaat verder in dezelfde sessie.", "Send your message. The agent continues in the same session.")} aria-label={tr("Stuur", "Send")} onclick={send}><Icon name="arrow" size={16} /></button>
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
  /* The composer surface: one rounded box with a hairline, the prompt on top and the controls in a row under it. */
  .box { border: 1px solid var(--line2); border-radius: var(--radius-composer); background: var(--surface); padding: 10px 8px 8px 12px; display: flex; flex-direction: column; gap: 6px; transition: border-color 120ms ease; }
  .box:focus-within { border-color: color-mix(in srgb, var(--paper) 22%, var(--line2)); }
  textarea { background: transparent; border: none; resize: none; padding: 2px 0; min-height: 44px; max-height: 200px; font-size: 14px; line-height: 1.5; }
  textarea:focus, textarea:focus-visible { border: none; box-shadow: none; }
  .bar { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
  .pill { background: none; border: none; height: 28px; padding: 0 8px; font-size: 13px; font-weight: 500; color: var(--text2); border-radius: var(--radius-control); display: inline-flex; gap: 6px; align-items: center; }
  .pill:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
  .hot { color: var(--coral); }
  .adot { width: 7px; height: 7px; border-radius: 50%; background: var(--paper); display: inline-block; }
  .sep { width: 1px; height: 16px; background: var(--line2); margin: 0 2px; }
  .spacer { flex: 1; }
  .pop { position: relative; }
  .menu { position: absolute; bottom: 34px; left: 0; z-index: 20; background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-panel); padding: 4px; display: flex; flex-direction: column; min-width: 180px; box-shadow: var(--shadow-popover); }
  .menu.wide { width: 300px; gap: 4px; padding: 8px; }
  .menu button { background: none; border: none; text-align: left; padding: 6px 8px; border-radius: var(--radius-chip); font-size: 13px; }
  .menu button:hover:not(:disabled) { background: var(--row-hover); }
  .menu button.chosen { background: var(--row-selected); }
  .menu hr { border: none; border-top: 1px solid var(--line2); margin: 3px 0; width: 100%; }
  .opt { display: flex; flex-direction: column; gap: 2px; }
  .mhead { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 2px 4px; }
  .mrow { display: flex; gap: 8px; align-items: center; justify-content: space-between; font-size: 11.5px; }
  .ctx { font-family: var(--mono); font-size: 11px; color: var(--text3); }
  .ctx.warning { color: var(--amber); }
  .ctx.critical { color: var(--coral); }
  /* The send and stop buttons: 32 px circles at the composer's corner. */
  .round { display: grid; place-items: center; width: 32px; height: 32px; padding: 0; border-radius: 50%; flex: none; }
  .stop { background: var(--paper); color: var(--on-iris); border-color: transparent; }
  .stop:hover:not(:disabled) { background: color-mix(in srgb, var(--paper) 85%, var(--canvas)); }
  .send { height: 32px; padding: 0 14px; border-radius: 999px; }
  .hint { font-size: 11px; margin: 0; }
  .small { font-size: 11px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
