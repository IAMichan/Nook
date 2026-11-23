<script lang="ts">
  import { tip } from "../../components/ui/tip";
  // Settings › Automation (`WorkspaceSettingsSection`, part automation, and `ScheduledTasksView` on the Mac): scheduled
  // tasks that start a session at a time, at an interval or from a signed local webhook, their list, and the workspace
  // Nook offers agents. The Mac lists the tasks in a sheet; here they stay on the page.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { api } from "../../lib/api";
  import { agents } from "../../lib/agents.svelte";
  import { permissionLabels, type RunProvider } from "../../lib/workspace/api";
  import {
    automationApi, autonomyLevels, blankTask, curlExample, editorValues, presetOf, problem, reasonLabel, ruleFor, ruleLabel, statusLabel,
    weekdayOrder, weekdayShort, type AutomationOverview, type NookAutonomy, type Preset, type ScheduledTask,
  } from "../../lib/workspace/automation";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import AgentsWorkspace from "./AgentsWorkspace.svelte";

  let view = $state<AutomationOverview | null>(null);
  let error = $state<string | null>(null);
  let notice = $state<string | null>(null);
  let editing = $state<ScheduledTask | null>(null);
  let preset = $state<Preset>("daily");
  let values = $state(editorValues({ type: "fixedTime", hour: 9, minute: 0, weekdays: [] }));
  let portDraft = $state("");
  let confirmDelete = $state<string | null>(null);

  async function load() {
    try {
      view = await automationApi.overview();
      portDraft = String(view.settings.webhookPort || 0);
    } catch (e) {
      error = String(e);
    }
  }

  $effect(() => {
    workspace.start();
    load();
    const off = automationApi.onChanged(load);
    return () => {
      off.then((f) => f());
    };
  });

  async function act(f: () => Promise<unknown>) {
    error = null;
    try {
      await f();
    } catch (e) {
      error = String(e);
    }
    await load();
  }

  function saveSettings() {
    if (!view) return;
    act(() => automationApi.saveSettings($state.snapshot(view!.settings)));
  }

  const portValid = $derived(portDraft.trim() === "0" || (/^\d+$/.test(portDraft.trim()) && Number(portDraft) >= 1024 && Number(portDraft) <= 65535));
  function savePort() {
    if (!view || !portValid) return;
    view.settings.webhookPort = Number(portDraft);
    saveSettings();
  }

  const projects = $derived([...new Set([...(workspace.settings?.favoriteProjects ?? []), ...(workspace.settings?.recentProjects ?? [])])]);
  const providers = $derived(workspace.providers.filter((p) => p.supported));
  const sessions = $derived(workspace.runs.filter((r) => !r.archived));

  function begin(task?: ScheduledTask) {
    const t = task ? structuredClone($state.snapshot(task)) : blankTask(projects[0] ?? "", (workspace.settings?.defaultProvider ?? "claude") as RunProvider);
    editing = t;
    preset = presetOf(t.rule);
    values = editorValues(t.rule);
  }

  const draftRule = $derived(editing ? ruleFor(preset, values) : null);
  const draftProblem = $derived(editing && draftRule ? problem({ ...editing, rule: draftRule }) : null);

  async function chooseFolder() {
    const picked = await openDialog({ directory: true, multiple: false }).catch(() => null);
    if (typeof picked === "string" && editing?.target.type === "newSession") editing.target.projectPath = picked;
  }

  function setDestination(kind: ScheduledTask["target"]["type"]) {
    if (!editing || editing.target.type === kind) return;
    editing.target = kind === "newSession"
      ? { type: "newSession", projectPath: projects[0] ?? "", provider: (workspace.settings?.defaultProvider ?? "claude") as RunProvider, profileId: null }
      : kind === "nook" ? { type: "nook" } : { type: "existingSession", id: sessions[0]?.id ?? "", fresh: false };
  }

  async function save() {
    if (!editing || !draftRule || draftProblem) return;
    const task = { ...$state.snapshot(editing), rule: draftRule };
    await act(() => automationApi.saveTask(task));
    if (!error) editing = null;
  }

  async function runNow(id: string, title: string) {
    error = null;
    notice = null;
    try {
      const result = await automationApi.runNow(id);
      if (result === "busy") notice = tr("“{title}” draait al.", "“{title}” is already running.", { title });
      if (result === "notAvailable") notice = tr("Zet geplande taken eerst aan.", "Turn on scheduled tasks first.");
    } catch (e) {
      error = String(e);
    }
    await load();
  }

  async function copy(text: string) {
    await navigator.clipboard.writeText(text).catch(() => {});
    notice = tr("Gekopieerd", "Copied");
  }

  function openSession(id: string) {
    agents.select(`run:${id}`);
    api.showMain("agents");
  }

  const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "");
</script>

{#if view}
  <!-- The Mac's Automation: scheduled tasks (on, the webhook port, the tasks), then the workspace for agents. Automatic
       titles are under Sessions › Behavior, as on the Mac. -->
  <div class="section-head">
    <h3>{tr("Geplande taken", "Scheduled tasks")}</h3>
    {#if !editing}
      <button class="head-action" onclick={() => begin()}><Ico name="plus" size={14} />{tr("Nieuwe taak", "New task")}</button>
    {/if}
  </div>
  <p class="section-info">{tr("Een taak start een gewone sessie met de rechten die jij bij de taak koos, standaard “Vragen”. Zolang dit uit staat, loopt er niets automatisch.", "A task starts an ordinary session with the permissions you chose for the task, “Ask” by default. While this is off nothing runs by itself.")}</p>
  <div class="group">
    <label class="row"><span>{tr("Geplande taken toestaan", "Allow scheduled tasks")}</span><input type="checkbox" role="switch" bind:checked={view.settings.scheduledTasks} onchange={saveSettings} /></label>
    {#if view.settings.scheduledTasks}
      <label class="row"><span>{tr("Poort voor webhooks (0 = uit)", "Port for webhooks (0 = off)")}</span>
        <input class="port" inputmode="numeric" bind:value={portDraft} onchange={savePort} />
      </label>
      {#if !portValid}<p class="note err">{tr("Kies een poort tussen 1024 en 65535, of 0 om webhooks uit te zetten.", "Choose a port between 1024 and 65535, or 0 to turn webhooks off.")}</p>{/if}
      {#if view.listening}<p class="note ok">{tr("Luistert op 127.0.0.1:{port} (alleen deze computer)", "Listening on 127.0.0.1:{port} (this computer only)", { port: view.listening })}</p>{/if}
      {#if view.listenerError}<p class="note err">{tr("De webhook-luisteraar kon niet starten: {error}", "The webhook listener could not start: {error}", { error: view.listenerError })}</p>{/if}
    {/if}
    {#each view.tasks as t (t.id)}
      <div class="task" class:off={!t.enabled}>
        <div class="line">
          <input type="checkbox" role="switch" use:tip={tr("Aan", "Enabled")} checked={t.enabled} onchange={(e) => act(() => automationApi.setEnabled(t.id, (e.target as HTMLInputElement).checked))} />
          <strong>{t.title || tr("Taak zonder naam", "Untitled task")}</strong>
          <span class="faint">{ruleLabel(t.rule)}</span>
          <span class="spacer"></span>
          <button class="ghost" disabled={t.running || !view.settings.scheduledTasks} onclick={() => runNow(t.id, t.title)}>{tr("Nu draaien", "Run now")}</button>
          <button class="ghost" onclick={() => begin(t)}>{tr("Bewerk", "Edit")}</button>
          <button class="ghost danger" onclick={() => (confirmDelete = t.id)}>{tr("Verwijder", "Delete")}</button>
        </div>
        <div class="meta faint">
          <span class="status {t.running ? 'running' : t.lastStatus ?? ''}">{t.running ? statusLabel("running") : statusLabel(t.lastStatus)}</span>
          {#if t.lastRun}<span>{tr("laatst {when}", "last {when}", { when: when(t.lastRun) })}</span>{/if}
          {#if t.rule.type === "webhook"}<span>{tr("wacht op een webhook", "waiting for a webhook")}</span>
          {:else if t.nextRun && t.enabled}<span>{tr("volgende {when}", "next {when}", { when: when(t.nextRun) })}</span>
          {:else if t.rule.type === "once" && t.lastRun}<span>{tr("Klaar", "Done")}</span>{/if}
          {#if t.lastSession && t.sessionTitle}<button class="link" onclick={() => openSession(t.lastSession!)}>{t.sessionTitle}</button>{/if}
        </div>
        {#if t.lastError && (t.lastStatus !== "succeeded" || t.lastError === "sched.nook.nothingNew")}<div class="meta faint">{reasonLabel(t.lastError)}</div>{/if}
        {#if t.rule.type === "webhook"}
          <div class="hook">
            {#if t.webhookUrl}
              <span class="mono">{t.webhookUrl}</span>
              <button class="ghost" onclick={() => copy(t.webhookUrl!)}>{tr("Kopieer adres", "Copy address")}</button>
              <button class="ghost" onclick={async () => copy(await automationApi.secret(t.id))}>{tr("Kopieer geheim", "Copy secret")}</button>
              <button class="ghost" onclick={() => act(async () => copy(await automationApi.secret(t.id, true)))}>{tr("Nieuw geheim", "New secret")}</button>
            {:else}
              <span class="faint">{tr("Kies eerst een poort hierboven om het webhook-adres te zien.", "Choose a port above first to see the webhook address.")}</span>
            {/if}
          </div>
        {/if}
        {#if confirmDelete === t.id}
          <div class="line">
            <span>{tr("“{title}” verwijderen?", "Delete “{title}”?", { title: t.title || tr("Taak zonder naam", "Untitled task") })}</span>
            <button class="danger" onclick={() => { confirmDelete = null; act(() => automationApi.deleteTask(t.id)); }}>{tr("Verwijder", "Delete")}</button>
            <button class="ghost" onclick={() => (confirmDelete = null)}>{tr("Annuleer", "Cancel")}</button>
          </div>
        {/if}
      </div>
    {:else}
      <p class="empty-note">{tr("Nog geen geplande taken. Een taak start een sessie op een vast tijdstip, met een interval, één keer of vanuit een webhook.", "No scheduled tasks yet. A task starts a session at a fixed time, at an interval, once or from a webhook.")}</p>
    {/each}
  </div>
  <p class="note">{tr("Taken draaien zolang Nook open is; een vast tijdstip dat meer dan 10 minuten gemist is (de computer sliep), wordt overgeslagen.", "Tasks run while Nook is open; a fixed time missed by more than 10 minutes (the computer was asleep) is skipped.")}</p>
  {#if !view.settings.scheduledTasks && view.tasks.length}
    <p class="faint note">{tr("Geplande taken staan uit. Tot je ze aanzet, draait er niets vanzelf.", "Scheduled tasks are off. Until you turn them on, nothing runs by itself.")}</p>
  {/if}

  {#if editing}
    <div class="editor">
      <label class="row"><span>{tr("Naam", "Name")}</span><input bind:value={editing.title} placeholder={tr("Bijvoorbeeld: ochtendcheck", "For example: morning check")} /></label>
      <label class="col"><span>{editing.target.type === "nook" ? tr("Wat Nook elke run doet", "What Nook does on each run") : tr("Prompt voor de agent", "Prompt for the agent")}</span><textarea rows="4" bind:value={editing.prompt}></textarea></label>

      <label class="row"><span>{tr("Wanneer", "When")}</span>
        <select bind:value={preset}>
          <option value="daily">{tr("Elke dag", "Every day")}</option>
          <option value="weekdays">{tr("Op bepaalde dagen", "On some days")}</option>
          <option value="interval">{tr("Interval", "Interval")}</option>
          <option value="once">{tr("Eén keer", "Once")}</option>
          <option value="webhook">{tr("Webhook", "Webhook")}</option>
          <option value="message">{tr("Bij een nieuw bericht", "On a new message")}</option>
        </select>
      </label>
      {#if preset === "daily" || preset === "weekdays"}
        <label class="row"><span>{tr("Om", "At")}</span><input type="time" bind:value={values.time} /></label>
        {#if preset === "weekdays"}
          <div class="days">
            {#each weekdayOrder as d (d)}
              <label class="day"><input class="box" type="checkbox" checked={values.weekdays.includes(d)} onchange={(e) => { values.weekdays = (e.target as HTMLInputElement).checked ? [...values.weekdays, d] : values.weekdays.filter((x) => x !== d); }} /> {weekdayShort(d)}</label>
            {/each}
          </div>
          <p class="faint note">{tr("Geen dag gekozen is maandag tot en met vrijdag.", "No day chosen means Monday to Friday.")}</p>
        {/if}
      {:else if preset === "message"}
        <label class="row"><span>{tr("Apps", "Apps")}</span><input bind:value={values.apps} placeholder={tr("Leeg: elke app. Bijvoorbeeld: whatsapp", "Empty: every app. For example: whatsapp")} /></label>
        <label class="row"><span>{tr("Van", "From")}</span><input bind:value={values.from} placeholder={tr("Leeg: iedereen", "Empty: anyone")} /></label>
        <label class="row"><span>{tr("Woorden", "Words")}</span><input bind:value={values.keywords} placeholder={tr("Leeg: elk bericht. Gescheiden door komma’s", "Empty: any message. Separated by commas")} /></label>
        <label class="check"><input type="checkbox" role="switch" bind:checked={values.groups} /> {tr("Ook groepsgesprekken", "Group chats too")}</label>
        <p class="faint note">{tr("Draait zodra er een bericht van iemand anders binnenkomt dat past, één keer per bericht. Wat binnenkomt terwijl de taak draait, wacht op de volgende run. Het bericht komt bij Nook aan als gegevens, nooit als opdracht. Nu nog alleen WhatsApp.", "Runs as soon as a matching message from someone else comes in, once per message. What arrives while the task runs waits for the next run. The message reaches Nook as data, never as an instruction. Only WhatsApp for now.")}</p>
      {:else if preset === "interval"}
        <label class="row"><span>{tr("Elke", "Every")}</span><span class="inline"><input class="port" type="number" min="1" bind:value={values.minutes} /> {tr("minuten", "minutes")}</span></label>
        <p class="faint note">{tr("Minstens 1 minuut. Het interval telt vanaf het einde van de vorige run, dus runs stapelen nooit op.", "At least 1 minute. The interval counts from the end of the previous run, so runs never pile up.")}</p>
      {:else if preset === "once"}
        <label class="row"><span>{tr("Op", "On")}</span><input type="datetime-local" bind:value={values.at} /></label>
        <p class="faint note">{tr("Draait één keer op dit moment, daarna is de taak klaar. Slaapt de computer dan, dan draait hij zodra Nook weer wakker is.", "Runs one time at this moment, then the task is done. If the computer is asleep then, it runs as soon as Nook is awake again.")}</p>
      {:else}
        <p class="faint note">{tr("Stuur een POST met de header X-Hub-Signature-256: sha256=<HMAC-SHA256 van de body met het geheim> en een unieke X-Nook-Delivery. Zonder geldige handtekening start er niets. De inhoud komt bij de agent aan als onbetrouwbare gegevens. Gebruik {{body.pad}} of {{headers.naam}} in de prompt om alleen die waarden mee te geven. Na bewaren krijg je het adres en het geheim.", "Send a POST with the header X-Hub-Signature-256: sha256=<HMAC-SHA256 of the body with the secret> and a unique X-Nook-Delivery. Nothing starts without a valid signature. The content reaches the agent as untrusted data. Use {{body.path}} or {{headers.name}} in the prompt to pass only those values. After saving you get the address and the secret.")}</p>
        {#if view.listening}<pre class="mono">{curlExample(`http://127.0.0.1:${view.listening}/hooks/${editing.id}`)}</pre>{/if}
      {/if}

      <label class="row"><span>{tr("Waar runs heen gaan", "Where runs go")}</span>
        <select value={editing.target.type} onchange={(e) => setDestination((e.target as HTMLSelectElement).value as ScheduledTask["target"]["type"])}>
          <option value="newSession">{tr("Elke run een nieuwe sessie", "New session each run")}</option>
          <option value="existingSession">{tr("Eén sessie", "One session")}</option>
          <option value="nook">{tr("Nook Chat beantwoordt het", "Nook Chat answers it")}</option>
        </select>
      </label>
      {#if editing.target.type === "nook"}
        <label class="check"><input type="checkbox" role="switch" bind:checked={editing.quiet} /> {tr("Alleen melden als er iets nieuws is", "Only speak up for something new")}</label>
        <label class="row"><span>{tr("Wat Nook zelf doet", "What Nook does by itself")}</span>
          <select value={editing.autonomy ?? "ask"} onchange={(e) => { if (editing) editing.autonomy = (e.target as HTMLSelectElement).value as NookAutonomy; }}>
            {#each autonomyLevels() as level (level.id)}<option value={level.id}>{level.label}</option>{/each}
          </select>
        </label>
        <p class="faint note">{autonomyLevels().find((l) => l.id === (editing?.autonomy ?? "ask"))?.detail}</p>
        {#if (editing.autonomy ?? "ask") !== "ask"}
          <p class="faint note">{preset === "webhook"
            ? tr("Deze taak start op een webhook van iemand anders, dus Nook controleert elke stap eerst, ook bij Gewoon doen. Verwijderen, mergen, opdrachten, instellingen en betalingen wachten altijd op jou.", "This task starts on a webhook from someone else, so Nook always checks each step first, also on Do it. Deleting, merging, commands, settings and payments always wait for you.")
            : tr("Alleen berichten, je agenda, herinneringen, notities en reacties kunnen vanzelf, hooguit 12 stappen per run. Mail wacht altijd op jou, net als verwijderen, mergen, opdrachten, instellingen en betalingen; alles wat draait staat in het auditlog.", "Only messages, your calendar, reminders, notes and comments can run by themselves, at most 12 steps a run. Mail always waits for you, as do deleting, merging, commands, settings and payments; everything that runs is in the audit log.")}</p>
        {/if}
        <p class="faint note">{tr("Elke run is een eigen gesprek in Nook Chat. Nook zoekt zelf op en zet antwoorden en acties klaar; niets wordt verstuurd of veranderd zonder jouw OK.", "Each run is a conversation of its own in Nook Chat. Nook looks things up and prepares replies and actions; nothing is sent or changed without your OK.")}</p>
      {:else if editing.target.type === "newSession"}
        <div class="row"><span>{tr("Projectmap", "Project folder")}</span>
          <span class="inline">
            <select bind:value={editing.target.projectPath}>
              {#if !editing.target.projectPath}<option value="">{tr("Geen map gekozen", "No folder chosen")}</option>{/if}
              {#each [...new Set([editing.target.projectPath, ...projects].filter(Boolean))] as p (p)}<option value={p}>{p}</option>{/each}
            </select>
            <button class="ghost" onclick={chooseFolder}>{tr("Kies…", "Choose…")}</button>
          </span>
        </div>
        <label class="row"><span>{tr("Agent", "Agent")}</span>
          <select bind:value={editing.target.provider}>{#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}</select>
        </label>
      {:else}
        <label class="row"><span>{tr("Sessie", "Session")}</span>
          <select bind:value={editing.target.id}>
            {#if !sessions.some((r) => editing?.target.type === "existingSession" && r.id === editing.target.id)}<option value={editing.target.id}>{editing.target.id ? tr("Een sessie die niet meer bestaat", "A session that no longer exists") : tr("Kies een sessie", "Choose a session")}</option>{/if}
            {#each sessions as r (r.id)}<option value={r.id}>{r.title}</option>{/each}
          </select>
        </label>
        <label class="row"><span>{tr("Gesprek", "Conversation")}</span>
          <select bind:value={editing.target.fresh}>
            <option value={false}>{tr("Het gesprek voortzetten", "Continue the conversation")}</option>
            <option value={true}>{tr("Elke run een nieuw gesprek", "Fresh conversation each run")}</option>
          </select>
        </label>
        <p class="faint note">{editing.target.fresh
          ? tr("Elke run begint opnieuw in deze sessie: de agent ziet alleen de prompt van de taak, de tijdlijn van de sessie bewaart elke run.", "Each run starts over in this session: the agent sees only the task's prompt, the session's timeline keeps every run.")
          : tr("Elke run is een bericht in het gesprek van de sessie, dus de agent onthoudt eerdere runs. Een sessie die nog werkt, wordt niet onderbroken: die run wordt overgeslagen.", "Each run is a message in the session's conversation, so the agent remembers earlier runs. A session that is still working is not interrupted: that run is skipped.")}</p>
      {/if}

      {#if editing.target.type === "newSession"}
        <label class="row"><span>{tr("Rechten van de sessie", "Session permissions")}</span>
          <select bind:value={editing.permission}>
            <option value="ask">{permissionLabels.ask}</option>
            <option value="acceptEdits">{permissionLabels.acceptEdits}</option>
          </select>
        </label>
        <p class="faint note">{preset === "webhook"
          ? tr("Een sessie die een webhook start, vraagt altijd om toestemming: de inhoud komt van buiten en is geen opdracht van jou.", "A session started by a webhook always asks for approval: the content comes from outside and is not an instruction from you.")
          : tr("Standaard is ‘Vraag’: elke wijziging en elk commando wacht op jouw OK. Alles zonder vragen kan niet voor een taak die draait terwijl je weg bent.", "Default is “Ask”: every edit and command waits for your OK. Everything without asking is not offered for a task that runs while you are away.")}</p>
      {/if}

      {#if draftProblem}<p class="err">{draftProblem}</p>{/if}
      <div class="line">
        <span class="spacer"></span>
        <button class="ghost" onclick={() => (editing = null)}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={!!draftProblem} onclick={save}>{tr("Bewaar", "Save")}</button>
      </div>
    </div>
  {/if}

  {#if notice}<p class="ok">{notice}</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}
  <AgentsWorkspace part="bridge" />
{:else}
  <p class="faint">{tr("Laden…", "Loading…")}</p>
{/if}

<style>
  /* The tasks as rows in the card, as the Mac's task list; the editor as a card of its own under it. */
  .col { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-12) 0; border-bottom: 1px solid var(--separator); }
  .inline { display: flex; gap: var(--space-6); align-items: center; }
  .check { display: flex; gap: var(--space-8); align-items: center; }
  .ok { color: var(--mint) !important; }
  .err { color: var(--coral) !important; }
  .port { width: 90px; }
  .task { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-12) 0; border-bottom: 1px solid var(--separator); }
  .task:last-child { border-bottom: none; }
  .task.off { opacity: 0.7; }
  .line { display: flex; gap: var(--space-8); align-items: center; flex-wrap: wrap; margin-top: var(--space-8); }
  .task .line { margin-top: 0; }
  .spacer { flex: 1; }
  .meta { display: flex; gap: 10px; font: var(--text-detail); flex-wrap: wrap; }
  .status.failed { color: var(--coral); }
  .status.succeeded { color: var(--mint); }
  .hook { display: flex; gap: var(--space-6); align-items: center; flex-wrap: wrap; font: var(--text-detail); }
  .mono { font: var(--text-code); }
  pre.mono { white-space: pre-wrap; word-break: break-all; margin: 0; padding: var(--space-6) var(--space-8); background: var(--row-hover); border-radius: var(--radius-chip); }
  .editor { margin-top: var(--space-8); background: var(--surface); border: 1px solid var(--separator); border-radius: var(--radius-panel); padding: 0 var(--space-16) var(--space-12); display: flex; flex-direction: column; }
  .days { display: flex; gap: var(--space-8); flex-wrap: wrap; font: var(--text-detail); padding: var(--space-8) 0; }
  .day { display: flex; gap: var(--space-4); align-items: center; }
  .link { background: none; border: none; padding: 0; color: var(--paper); text-decoration: underline; cursor: pointer; font: var(--text-detail); }
  .danger { color: var(--coral); }
</style>
