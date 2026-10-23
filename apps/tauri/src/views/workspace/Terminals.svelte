<script lang="ts">
  // De terminals (`TerminalsView` en `SessionTerminalsView` op de Mac): tabs voor elke open terminal, een nieuwe in
  // een map naar keuze, en de terminal zelf. Met `folder` alleen de terminals van die map (een sessie), met de scripts
  // van het project (nook.json) en de dev-servers die daar luisteren.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { nook } from "../../lib/state.svelte";
  import { toolEvents, toolsApi, type DevServer, type ProjectScript, type TerminalInfo } from "../../lib/workspace/api";
  import TerminalView from "./TerminalView.svelte";

  let { folder = null }: { folder?: string | null } = $props();
  let terminals = $state<TerminalInfo[]>([]);
  let selected = $state<string | null>(null);
  let scripts = $state<ProjectScript[]>([]);
  let servers = $state<DevServer[]>([]);
  let error = $state<string | null>(null);
  let scriptsOpen = $state(false);
  let started = false;

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

  async function loadFolder() {
    if (!folder) return;
    try {
      const t = await toolsApi.folderTools(folder);
      scripts = t.scripts;
      servers = t.servers;
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
    <p>Terminals draaien op je computer, niet op je telefoon.</p>
  </div>
{:else}
  <div class="terminals">
    <div class="bar">
      <div class="tabs">
        {#each mine as t (t.id)}
          <div class="tab" class:on={shown?.id === t.id}>
            <button class="name" onclick={() => (selected = t.id)} title={t.command ?? t.origin}>
              <span class="dot {t.running ? 'working' : ''}"></span>{t.title}
              {#if !t.running}<span class="faint">gestopt ({t.exitCode ?? "?"})</span>{/if}
              {#if t.owner}<span class="faint">· {t.owner.agent}</span>{/if}
            </button>
            <button class="x" title="Sluit" onclick={() => close(t.id)}>✕</button>
          </div>
        {/each}
      </div>
      {#if folder && scripts.length}
        <span class="pop">
          <button class="ghost" title="Scripts van dit project (nook.json)" onclick={(e) => { e.stopPropagation(); scriptsOpen = !scriptsOpen; }}>▶</button>
          {#if scriptsOpen}
            <div class="menu">
              {#each scripts as s (s.id)}<button title={s.command} onclick={() => run(s)}>{s.name}</button>{/each}
            </div>
          {/if}
        </span>
      {/if}
      <button class="ghost" onclick={() => open(folder ?? null)}>+ Nieuwe terminal</button>
      {#if !folder}<button class="ghost" onclick={inFolder}>In map…</button>{/if}
    </div>
    {#if servers.length}
      <div class="servers">
        {#each servers as s (s.port)}
          <button class="server" title={`${s.command} (pid ${s.pid})`} onclick={() => toolsApi.go(s.url)}>◍ {s.url}</button>
        {/each}
      </div>
    {/if}
    {#if error}<p class="err">{error}</p>{/if}
    {#if shown}
      {#key shown.id}<TerminalView id={shown.id} />{/key}
    {:else}
      <div class="empty">
        <p>Nog geen terminal open</p>
        <p class="faint">Open een terminal in een map, of kies bij een agentsessie Open terminal. Inloggen bij een agent gebeurt hier ook.</p>
        <button onclick={() => open(folder ?? null)}>Nieuwe terminal</button>
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
  .empty { text-align: center; padding: 24px; display: flex; flex-direction: column; align-items: center; gap: 6px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
