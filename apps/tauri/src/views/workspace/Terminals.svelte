<script lang="ts">
  // De terminals (`TerminalsView` en `SessionTerminalsView` op de Mac): tabs voor elke open terminal, een nieuwe in
  // een map naar keuze, en de terminal zelf. Met `folder` alleen de terminals van die map (een sessie), met de scripts
  // van het project (nook.json) en de dev-servers die daar luisteren.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { tr } from "../../lib/i18n.svelte";
  import { nook } from "../../lib/state.svelte";
  import { toolEvents, toolsApi, type DevServer, type ProjectScript, type TerminalInfo } from "../../lib/workspace/api";
  import TerminalView from "./TerminalView.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import EmptyState from "../agents/EmptyState.svelte";
  import PageHeader from "../agents/PageHeader.svelte";

  /** `page`: the Agents area's "All terminals" page (the Mac's `TerminalsView`), a title and the terminals in a card. */
  let { folder = null, focusId = null, page = false }: { folder?: string | null; focusId?: string | null; page?: boolean } = $props();
  let terminals = $state<TerminalInfo[]>([]);
  let selected = $state<string | null>(null);
  let scripts = $state<ProjectScript[]>([]);
  let servers = $state<DevServer[]>([]);
  let error = $state<string | null>(null);
  let scriptsOpen = $state(false);
  let started = false;

  $effect(() => {
    if (focusId) selected = focusId;
  });

  const available = $derived(nook.info?.capabilities.terminals ?? true);
  const within = (origin: string, root: string) => {
    const r = root.replace(/[\\/]+$/, "");
    return origin === r || origin.startsWith(r + "/") || origin.startsWith(r + "\\");
  };
  const mine = $derived(folder ? terminals.filter((t) => within(t.origin, folder!)) : terminals);
  const shown = $derived(mine.find((t) => t.id === selected) ?? mine[mine.length - 1] ?? null);

  async function load() {
    try {
      terminals = await toolsApi.terminals();
    } catch (e) {
      error = String(e);
    }
  }

  let serverNote = $state<string | null>(null);
  /// Stops a server Nook started; for any other it says why not, as stopping something you run elsewhere would take it away
  /// behind your back.
  async function stopServer(s: DevServer) {
    const notOurs = tr("{command} op poort {port} is niet door Nook of een van zijn sessies gestart. Stop hem waar je hem startte, zodat niets wat je elders draait achter je rug verdwijnt.", "{command} on port {port} was not started by Nook or one of its sessions. Stop it where you started it, so nothing you run elsewhere disappears behind your back.", { command: s.command, port: s.port });
    if (!s.startedByNook || !folder) { serverNote = serverNote ? null : notOurs; return; }
    const stopped = await toolsApi.stopDevServer(folder, s.pid, s.port).catch(() => false);
    serverNote = stopped ? null : notOurs;
    setTimeout(loadFolder, 700);
  }

  async function loadFolder() {
    if (!folder) return;
    try {
      const t = await toolsApi.folderTools(folder);
      scripts = t.scripts;
      servers = await toolsApi.devServers(folder).catch(() => t.servers);
    } catch {
      scripts = [];
      servers = [];
    }
  }

  $effect(() => {
    if (!available) return;
    let un: (() => void) | null = null;
    let gone = false;
    load().then(() => {
      // Een sessie die je voor het eerst opent, krijgt meteen een terminal in haar map.
      if (folder && !started && !mine.length) {
        started = true;
        open(folder);
      }
    });
    loadFolder();
    toolEvents.onTerminals(load).then((u) => (gone ? u() : (un = u)));
    const timer = setInterval(loadFolder, 15_000);
    return () => {
      gone = true;
      un?.();
      clearInterval(timer);
    };
  });

  async function open(directory: string | null, command: string | null = null, title: string | null = null) {
    error = null;
    try {
      const t = await toolsApi.openTerminal(directory, command, title);
      await load();
      selected = t.id;
    } catch (e) {
      error = String(e);
    }
  }

  async function inFolder() {
    const picked = await openDialog({ directory: true, multiple: false, defaultPath: folder ?? undefined }).catch(() => null);
    if (typeof picked === "string") open(picked);
  }

  async function close(id: string) {
    await toolsApi.closeTerminal(id).catch(() => {});
    await load();
  }

  /// Een script in een eigen tab; een script dat een pagina serveert, opent die even later in de browser van Nook.
  async function run(s: ProjectScript) {
    scriptsOpen = false;
    await open(folder, s.command, s.name);
    if (s.autoOpenPreview && s.previewUrl) setTimeout(() => toolsApi.go(s.previewUrl!).catch(() => {}), 4000);
  }
</script>

{#if !available}
  <div class="empty">
    <p>{tr("Terminals draaien op je computer, niet op je telefoon.", "Terminals run on your computer, not on your phone.")}</p>
  </div>
{:else}
  {#if page}<PageHeader title={tr("Alle terminals", "All terminals")} />{/if}
  <div class="terminals" class:page>
    <div class="bar">
      {#if page && !folder}
        <!-- The card's toolbar (`TerminalsView`): a new terminal in a folder on the left, the terminal's buttons on the right. -->
        <button class="chip" onclick={inFolder}><Ico name="folder" size={13} />{tr("In map…", "In folder…")}</button>
      {/if}
      <div class="tabs">
        {#each mine as t (t.id)}
          <div class="tab" class:on={shown?.id === t.id}>
            <button class="name" onclick={() => (selected = t.id)} title={t.command ?? t.origin}>
              <span class="dot {t.running ? 'working' : ''}"></span>{t.title}
              {#if !t.running}<span class="faint">{tr("gestopt ({code})", "stopped ({code})", { code: t.exitCode ?? "?" })}</span>{/if}
              {#if t.owner}<span class="faint">· {t.owner.agent}</span>{/if}
            </button>
            <button class="x" title={tr("Sluit", "Close")} onclick={() => close(t.id)}>✕</button>
          </div>
        {/each}
      </div>
      {#if folder && scripts.length}
        <span class="pop">
          <button class="ghost" title={tr("Scripts van dit project (nook.json)", "Scripts of this project (nook.json)")} onclick={(e) => { e.stopPropagation(); scriptsOpen = !scriptsOpen; }}>▶</button>
          {#if scriptsOpen}
            <div class="menu">
              {#each scripts as s (s.id)}<button title={s.command} onclick={() => run(s)}>{s.name}</button>{/each}
            </div>
          {/if}
        </span>
      {/if}
      {#if page}
        <span class="tools">
          <button class="tool" title={tr("Nieuwe terminal", "New terminal")} aria-label={tr("Nieuwe terminal", "New terminal")} onclick={() => open(folder ?? null)}><Ico name="plus" size={14} stroke={2.2} /></button>
          <button class="tool" title={tr("Sluit", "Close")} aria-label={tr("Sluit", "Close")} disabled={!shown} onclick={() => shown && close(shown.id)}><Ico name="trash-2" size={14} /></button>
        </span>
      {:else}
        <button class="ghost" onclick={() => open(folder ?? null)}>+ {tr("Nieuwe terminal", "New terminal")}</button>
        {#if !folder}<button class="ghost" onclick={inFolder}>{tr("In map…", "In folder…")}</button>{/if}
      {/if}
    </div>
    {#if servers.length}
      <div class="servers">
        {#each servers as s (s.port)}
          <span class="server-chip">
            <button class="server" title={`${s.command} (pid ${s.pid})`} onclick={() => toolsApi.go(s.url)}>◍ {s.url}</button>
            <button class="stop" class:muted={!s.startedByNook} aria-label={tr("Stop de server op poort {port}", "Stop the server on port {port}", { port: s.port })}
              title={s.startedByNook ? tr("Stop de server op poort {port}", "Stop the server on port {port}", { port: s.port }) : tr("Nook heeft deze server niet gestart en kan hem dus niet stoppen", "Nook did not start this server, so it can't stop it")}
              onclick={() => stopServer(s)}><Ico name="square" size={8} stroke={3} fill="currentColor" /></button>
          </span>
        {/each}
      </div>
    {/if}
    {#if serverNote}<p class="faint note">{serverNote}</p>{/if}
    {#if error}<p class="err">{error}</p>{/if}
    {#if shown}
      {#key shown.id}<TerminalView id={shown.id} />{/key}
    {:else if page}
      <EmptyState symbol="terminal" title={tr("Nog geen terminal open", "No terminal open yet")}
        message={tr("Open een terminal in een map, of kies bij een agentsessie Open terminal. Inloggen bij een agent gebeurt hier ook.", "Open a terminal in a folder, or choose Open terminal on an agent session. Signing in to an agent happens here too.")}
        action={{ title: tr("Nieuwe terminal", "New terminal"), run: () => open(folder ?? null) }} />
    {:else}
      <div class="empty">
        <p>{tr("Nog geen terminal open", "No terminal open yet")}</p>
        <p class="faint">{tr("Open een terminal in een map, of kies bij een agentsessie Open terminal. Inloggen bij een agent gebeurt hier ook.", "Open a terminal in a folder, or choose Open terminal on an agent session. Signing in to an agent happens here too.")}</p>
        <button onclick={() => open(folder ?? null)}>{tr("Nieuwe terminal", "New terminal")}</button>
      </div>
    {/if}
  </div>
{/if}

<svelte:window onclick={() => (scriptsOpen = false)} />

<style>
  .terminals { display: flex; flex-direction: column; gap: 6px; height: 100%; min-height: 0; }
  .bar { display: flex; gap: 6px; align-items: center; }
  .tabs { display: flex; gap: 6px; overflow-x: auto; flex: 1; min-width: 0; }
  .tab { display: flex; align-items: center; border-radius: 8px; background: var(--graphite); }
  .tab.on { background: var(--smoke); }
  .tab button { background: none; border: none; font-size: 12px; padding: 4px 8px; white-space: nowrap; display: flex; gap: 6px; align-items: center; }
  .tab .x { padding: 4px 6px; color: var(--text3); }
  .pop { position: relative; }
  .menu { position: absolute; top: 30px; right: 0; z-index: 20; background: var(--graphite); border: 1px solid var(--line2); border-radius: 10px; padding: 4px; display: flex; flex-direction: column; min-width: 180px; }
  .menu button { background: none; border: none; text-align: left; padding: 6px 8px; font-size: 12.5px; }
  .menu button:hover { background: var(--smoke); }
  .servers { display: flex; gap: 6px; flex-wrap: wrap; }
  .server { font-size: 11.5px; padding: 2px 8px; border-radius: 999px; }
  .server-chip { display: inline-flex; align-items: center; gap: var(--space-2); }
  .stop { display: grid; place-items: center; width: 18px; height: 22px; margin: 0; padding: 0; border: 0; background: transparent; color: var(--text2); }
  .stop.muted { color: var(--text3); }
  .note { margin: 0; font: var(--text-detail); }
  .empty { text-align: center; padding: 24px; display: flex; flex-direction: column; align-items: center; gap: 6px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  /* The page's card: the terminals on a surface under the title, inset from the window's edges. */
  .terminals.page { height: auto; flex: 1; margin: 0 var(--space-16) var(--space-16) var(--space-16); padding: var(--space-6); border-radius: var(--radius-panel); background: var(--surface); }
  .chip { display: inline-flex; align-items: center; gap: var(--space-6); height: 24px; padding: 0 var(--space-8); margin: 0; border: 0; border-radius: var(--radius-chip); background: var(--smoke); font: var(--text-label); color: var(--text2); white-space: nowrap; }
  .chip:hover { color: var(--paper); }
  .tools { display: inline-flex; gap: var(--space-2); padding: var(--space-2); border-radius: var(--radius-control); background: var(--graphite); }
  .tool { display: grid; place-items: center; width: 26px; height: 22px; padding: 0; margin: 0; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text2); }
  .tool:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
</style>
