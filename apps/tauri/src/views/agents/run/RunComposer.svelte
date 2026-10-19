<script lang="ts">
  // Het invoerveld van een sessie die Nook draait (de composer in `AgentRunPanel`, met `QueuedMessagesStrip` en
  // `UsageLimitBanner`): je vervolgbericht, of terwijl de agent werkt bijsturen of in de wachtrij; daaronder de
  // keuzes voor de volgende beurt (model, modus, rechten, denkniveau) en ⋯ voor de rest.
  import {
    effortLabels, effortLevels, isActive, modeHelp, permissionHelp, permissionLabels, workspaceApi,
    type PermissionPolicy, type WorkspaceRun,
  } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { contextLevel, contextPercent, duration, oneLine } from "../../../lib/workspace/timeline";

  let {
    run,
    onrename,
    ondelete,
    onchanges,
  }: { run: WorkspaceRun; onrename: () => void; ondelete: () => void; onchanges: () => void } = $props();

  const key = $derived(`ws.draft.${run.id}`);
  let draft = $state("");
  let editing = $state<string | null>(null);
  let savedDraft = "";
  let menu = $state<"" | "more" | "permission" | "effort" | "model">("");
  let modelDraft = $state("");
  let collapsed = $state(false);
  let textarea = $state<HTMLTextAreaElement>();
  let now = $state(Date.now());

  $effect(() => {
    try {
      draft = localStorage.getItem(key) ?? "";
    } catch {
      draft = "";
    }
    workspace.loadQueue(run.id);
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

  $effect(() => {
    const t = setInterval(() => (now = Date.now()), 30_000);
    return () => clearInterval(t);
  });

  const active = $derived(isActive(run.status));
  const caps = $derived(workspace.provider(run.provider)?.capabilities);
  const queue = $derived(workspace.queues[run.id]);
  const steerDefault = $derived(workspace.settings?.steerByDefault ?? true);
  const canSteer = $derived(active && !!caps?.steering);
  const steers = $derived(canSteer && steerDefault);
  const short = $derived(run.provider === "claude" ? "Claude" : workspace.provider(run.provider)?.name ?? run.provider);
  const prompt = $derived(active ? (steers ? `${short} is bezig… typ om bij te sturen` : `${short} is bezig… typ een vervolg voor de wachtrij`) : "Stuur een vervolgbericht…");
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

  function limitLine(): string {
    if (!run.limitResetAt) return "Wanneer de limiet vrijkomt is onbekend; probeer het later zelf opnieuw.";
    const reset = Date.parse(run.limitResetAt);
    if (reset <= now) return run.autoResume ? "De limiet is vrij; de sessie gaat zo verder." : "De limiet is weer vrij. Stuur een bericht om verder te gaan.";
    const d = new Date(reset);
    const today = d.toDateString() === new Date(now).toDateString();
    const clock = today ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : d.toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
    const wait = duration((reset - now) / 1000);
    return run.autoResume ? `Gaat verder om ${clock} (over ${wait})` : `Vrij om ${clock} (over ${wait})`;
  }
</script>

<svelte:window onclick={() => (menu = "")} />

<div class="composer">
  {#if run.limitedAt && !active}
    <div class="limit">
      <span>{run.autoResume ? "↻" : "⌛"}</span>
      <div class="ltext"><strong>Gebruikslimiet bereikt</strong><span class="faint">{limitLine()}</span></div>
      {#if run.limitResetAt}
        <button class="ghost" title={'Stuurt "Continue where you left off." zodra de limiet vrij is. Een eigen bericht annuleert dit.'}
          onclick={() => workspace.act(() => workspaceApi.setAutoResume(run.id, !run.autoResume))}>
          {run.autoResume ? "Niet automatisch hervatten" : "Hervat bij reset"}
        </button>
      {/if}
    </div>
  {/if}

  {#if queue && queue.messages.length}
    <div class="queue">
      <button class="qhead" onclick={() => (collapsed = !collapsed)}>
        <span class="chev" class:open={!collapsed}>›</span> In de wachtrij ({queue.messages.length})
      </button>
      {#if !collapsed}
        {#each queue.messages as m, i (m.id)}
          <div class="qrow">
            <span class="faint">{editing === m.id ? "✎" : "◷"}</span>
            <span class="qtext">{oneLine(m.text, 120)}</span>
            {#if queue.messages.length > 1}
              <button class="icon" title="Omhoog" disabled={i === 0} onclick={() => queueAction(() => workspaceApi.queueMove(run.id, m.id, i - 1))}>↑</button>
              <button class="icon" title="Omlaag" disabled={i === queue.messages.length - 1} onclick={() => queueAction(() => workspaceApi.queueMove(run.id, m.id, i + 1))}>↓</button>
            {/if}
            <button class="icon" title="Bewerken" disabled={editing === m.id} onclick={() => beginEdit(m.id, m.text)}>✎</button>
            {#if canSteer}<button class="icon" title="Nu bijsturen" disabled={editing === m.id} onclick={() => queueAction(() => workspaceApi.queueSteer(run.id, m.id))}>↳</button>{/if}
            <button class="icon" title="Uit de wachtrij halen" onclick={() => { if (editing === m.id) cancelEdit(); queueAction(() => workspaceApi.queueRemove(run.id, m.id)); }}>✕</button>
          </div>
        {/each}
        <div class="qnote">
          <span class="faint">{queue.isHeld ? "De wachtrij is gepauzeerd na een fout of stop. Verstuur zelf of kies Nu versturen." : "Gaat vanzelf zodra de agent klaar is. Na een fout of stop wacht de rij op jou."}</span>
          {#if !active}<button class="ghost" onclick={() => queueAction(() => workspaceApi.queueSendNow(run.id))}>Nu versturen</button>{/if}
        </div>
      {/if}
    </div>
  {/if}

  <div class="box">
    <textarea bind:this={textarea} bind:value={draft} placeholder={editing ? "Bewerk het bericht in de wachtrij (Enter bewaart, Esc annuleert)" : prompt} rows="2" onkeydown={keydown}></textarea>
    <div class="bar">
      <div class="pop">
        <button class="pill" title="Instellingen en acties" onclick={(e) => { e.stopPropagation(); menu = menu === "more" ? "" : "more"; }}>⋯</button>
        {#if menu === "more"}
          <div class="menu" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
            {#if active}
              <button onclick={() => { menu = ""; workspace.act(() => workspaceApi.stop(run.id)); }}>Stop</button>
            {:else if run.status === "failed" || run.status === "stopped"}
              <button onclick={() => { menu = ""; workspace.act(() => workspaceApi.retry(run.id)); }}>Opnieuw</button>
            {/if}
            <button onclick={() => { menu = ""; onrename(); }}>Wijzig naam</button>
            <button disabled={!run.repoRoot} onclick={() => { menu = ""; onchanges(); }}>Wijzigingen bekijken</button>
            <hr />
            <button disabled={active} onclick={() => { menu = ""; workspace.act(() => workspaceApi.archive(run.id, !run.archived)); }}>{run.archived ? "Haal uit archief" : "Archiveer"}</button>
            <button class="danger" disabled={active} onclick={() => { menu = ""; ondelete(); }}>Verwijder</button>
          </div>
        {/if}
      </div>
      <div class="pop">
        <button class="pill" disabled={active} title={run.resolvedModel ?? "Model"} onclick={(e) => { e.stopPropagation(); modelDraft = run.model; menu = menu === "model" ? "" : "model"; }}>
          <span class="adot" style:background={workspace.provider(run.provider) ? undefined : "var(--text3)"}></span>
          {workspace.provider(run.provider)?.name ?? run.provider}{run.model ? ` · ${run.model}` : ""}
        </button>
        {#if menu === "model"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
            <div class="mhead">Model voor de volgende beurt</div>
            <input bind:value={modelDraft} placeholder="standaard" onkeydown={(e) => e.key === "Enter" && saveModel()} />
            <div class="mrow"><span class="faint">Leeg: de standaard van de agent.{#if run.resolvedModel} Nu: {run.resolvedModel}.{/if}</span><button class="primary" onclick={saveModel}>Bewaar</button></div>
          </div>
        {/if}
      </div>
      <span class="sep"></span>
      <button class="pill" disabled={active} title={modeHelp[run.mode] + " (klik om te wisselen tussen Agent en Plan)"}
        onclick={() => workspace.act(() => workspaceApi.configure(run.id, { mode: run.mode === "plan" ? "agent" : "plan" }))}>
        {run.mode === "plan" ? "Plan" : "Agent"}
      </button>
      <span class="sep"></span>
      <div class="pop">
        <button class="pill" class:hot={run.permission === "bypass" && run.mode !== "plan"} disabled={active || run.mode === "plan"}
          title={permissionHelp(run.permission, run.provider)} onclick={(e) => { e.stopPropagation(); menu = menu === "permission" ? "" : "permission"; }}>
          {run.permission === "bypass" ? "🔓" : "🔒"} {run.mode === "plan" ? "Alleen lezen" : permissionLabels[run.permission]}
        </button>
        {#if menu === "permission"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
            <div class="mhead">Toegang</div>
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
          <button class="pill" disabled={active} title="Hoe diep de agent nadenkt, vanaf de volgende beurt" onclick={(e) => { e.stopPropagation(); menu = menu === "effort" ? "" : "effort"; }}>
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
        <span class="ctx {contextLevel(fraction)}" title="Hoe vol het contextvenster zat bij de laatste modelaanroep">ctx {contextPercent(fraction)}</span>
      {/if}
      {#if active}
        {#if draft.trim()}
          <button class="pill" onclick={() => deliver(steers ? "steer" : "queue")} title={steers ? "Bijsturen: gaat nu naar de agent" : "In de wachtrij: gaat na deze beurt"}>{steers ? "Bijsturen" : "In de wachtrij"}</button>
        {/if}
        <button class="stop" title="Stop de agent (Ctrl+.)" onclick={() => workspace.act(() => workspaceApi.stop(run.id))}>■</button>
      {:else}
        <button class="primary send" disabled={!draft.trim()} title="Stuur je bericht. De agent gaat verder in dezelfde sessie." onclick={send}>{editing ? "Bewaar" : "Stuur"}</button>
      {/if}
    </div>
  </div>
  {#if !active && run.mode === "plan"}
    <p class="hint faint">Planmodus: de agent maakt alleen een plan. Zet de modus op Agent om het uit te laten voeren.</p>
  {/if}
  {#if workspace.error}<p class="err">{workspace.error}</p>{/if}
</div>

<style>
  .composer { display: flex; flex-direction: column; gap: 5px; }
  .limit { display: flex; gap: 9px; align-items: center; padding: 8px 10px; border: 1px solid rgba(255, 184, 77, 0.22); border-radius: 10px; font-size: 12px; }
  .ltext { flex: 1; display: flex; flex-direction: column; gap: 2px; }
  .queue { display: flex; flex-direction: column; gap: 4px; padding: 6px 8px; border-radius: 10px; background: var(--graphite); font-size: 12px; }
  .qhead { background: none; border: none; padding: 0; text-align: left; color: var(--text2); font-size: 12px; }
  .qhead:hover { background: none; color: var(--paper); }
  .chev { display: inline-block; transition: transform 0.15s; }
  .chev.open { transform: rotate(90deg); }
  .qrow { display: flex; gap: 8px; align-items: center; }
  .qtext { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .icon { background: none; border: none; padding: 0 3px; font-size: 11px; color: var(--text2); }
  .qnote { display: flex; gap: 8px; align-items: center; justify-content: space-between; font-size: 11.5px; }
  .box { border: 1px solid var(--line2); border-radius: 14px; background: var(--field); padding: 8px 10px; display: flex; flex-direction: column; gap: 6px; }
  textarea { background: transparent; border: none; resize: none; padding: 2px; min-height: 40px; max-height: 200px; }
  textarea:focus { border: none; }
  .bar { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
  .pill { background: none; border: none; padding: 3px 7px; font-size: 12px; color: var(--text2); border-radius: 8px; display: inline-flex; gap: 5px; align-items: center; }
  .pill:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  .hot { color: #ff9b9b; }
  .adot { width: 7px; height: 7px; border-radius: 50%; background: var(--paper); display: inline-block; }
  .sep { width: 1px; height: 14px; background: var(--line2); }
  .spacer { flex: 1; }
  .pop { position: relative; }
  .menu { position: absolute; bottom: 30px; left: 0; z-index: 20; background: var(--graphite); border: 1px solid var(--line2); border-radius: 10px; padding: 4px; display: flex; flex-direction: column; min-width: 180px; box-shadow: 0 8px 30px rgba(0, 0, 0, 0.5); }
  .menu.wide { width: 300px; gap: 4px; padding: 8px; }
  .menu button { background: none; border: none; text-align: left; padding: 6px 8px; border-radius: 7px; font-size: 12.5px; }
  .menu button:hover:not(:disabled) { background: var(--smoke); }
  .menu button.chosen { background: var(--smoke); }
  .menu hr { border: none; border-top: 1px solid var(--line2); margin: 3px 0; width: 100%; }
  .opt { display: flex; flex-direction: column; gap: 2px; }
  .mhead { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 2px 4px; }
  .mrow { display: flex; gap: 8px; align-items: center; justify-content: space-between; font-size: 11.5px; }
  .ctx { font-family: var(--mono); font-size: 11px; color: var(--text3); }
  .ctx.warning { color: var(--amber); }
  .ctx.critical { color: var(--coral); }
  .stop { border-radius: 50%; width: 28px; height: 28px; padding: 0; font-size: 10px; }
  .send { padding: 5px 14px; }
  .hint { font-size: 11px; margin: 0; }
  .small { font-size: 11px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
