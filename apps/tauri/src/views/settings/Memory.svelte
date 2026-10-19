<script lang="ts">
  // Geheugen: wat Nook over je weet, waar het vandaan komt en hoe zeker hij is. Alles is hier te zien, aan te passen,
  // vast te pinnen, op dit apparaat te houden of te vergeten. Nook leert alleen zelf als "Leer zelf" aan staat.
  import { brainApi, type MemoryItem, type MemoryOverview } from "../../lib/brain";
  import { nook } from "../../lib/state.svelte";

  const s = $derived(nook.settings!);
  let overview = $state<MemoryOverview | null>(null);
  let query = $state("");
  let adding = $state("");
  let editing = $state<Record<string, string>>({});
  let error = $state<string | null>(null);
  let confirmClear = $state(false);
  let imported = $state<string | null>(null);

  async function refresh() {
    overview = await brainApi.memory();
  }

  $effect(() => {
    refresh();
  });

  const kinds: { id: MemoryItem["kind"]; title: string }[] = [
    { id: "fact", title: "Feiten" },
    { id: "preference", title: "Voorkeuren" },
    { id: "lesson", title: "Geleerd van correcties" },
  ];
  const origin: Record<MemoryItem["origin"], string> = { told: "verteld", learned: "geleerd", observed: "gezien", imported: "geïmporteerd" };

  const filtered = $derived(
    (overview?.items ?? []).filter((m) => !query.trim() || `${m.text} ${m.subject}`.toLowerCase().includes(query.trim().toLowerCase())),
  );

  async function act(f: () => Promise<unknown>) {
    error = null;
    try {
      await f();
      await refresh();
    } catch (e) {
      error = String(e);
    }
  }

  function add() {
    const text = adding.trim();
    if (!text) return;
    act(async () => {
      await brainApi.memoryAdd(text);
      adding = "";
    });
  }

  function save(m: MemoryItem) {
    const text = editing[m.id]?.trim();
    if (!text) return;
    act(async () => {
      await brainApi.memoryEdit(m.id, text);
      delete editing[m.id];
    });
  }

  function focusField(node: HTMLInputElement) {
    node.focus();
    node.select();
  }

  function ago(iso: string | null): string {
    if (!iso) return "nog niet gebruikt";
    return new Date(iso).toLocaleDateString("nl-NL", { day: "numeric", month: "short", year: "numeric" });
  }

  function importGraph(path: string) {
    act(async () => {
      const n = await brainApi.memoryImport(path);
      imported = `${n} ${n === 1 ? "herinnering" : "herinneringen"} geïmporteerd.`;
    });
  }
</script>

<h2>Geheugen</h2>
<p class="muted">Wat Nook over je weet. Zeg in de chat "onthoud dat…" of "vergeet…", of pas het hier aan.</p>
<div class="group">
  <label class="row"><span>Gebruik wat Nook weet bij elke vraag</span><input type="checkbox" checked={s.useMemory} onchange={(e) => nook.saveSettings({ useMemory: e.currentTarget.checked })} /></label>
  <label class="row">
    <span>Leer zelf van gesprekken<br /><span class="faint small">Van je correcties, de plannen die je goedkeurt en de bronnen die je gebruikt.</span></span>
    <input type="checkbox" checked={s.learnFromChats} onchange={(e) => nook.saveSettings({ learnFromChats: e.currentTarget.checked })} />
  </label>
</div>
{#if overview?.localOnlySource}
  <p class="faint note">Geheugen staat bij Privacy op "alleen op dit apparaat": een externe AI krijgt het niet.</p>
{/if}

<div class="add">
  <input placeholder="Iets toevoegen, bijv. Mijn manager heet Sanne" bind:value={adding} onkeydown={(e) => e.key === "Enter" && add()} />
  <button onclick={add} disabled={!adding.trim()}>Onthoud</button>
</div>
{#if error}<p class="err">{error}</p>{/if}

{#if overview}
  {#if overview.items.length > 6}
    <input class="search" placeholder="Zoeken in het geheugen…" bind:value={query} />
  {/if}
  {#if !overview.items.length}
    <p class="faint note">Nook weet nog niets over je.</p>
  {/if}
  {#each kinds as kind (kind.id)}
    {@const items = filtered.filter((m) => m.kind === kind.id)}
    {#if items.length}
      <h3>{kind.title} · {items.length}</h3>
      <div class="group list">
        {#each items as m (m.id)}
          <div class="item">
            {#if editing[m.id] !== undefined}
              <div class="inline grow">
                <input class="grow" bind:value={editing[m.id]} use:focusField onkeydown={(e) => e.key === "Enter" && save(m)} />
                <button onclick={() => save(m)}>Bewaar</button>
                <button class="ghost" onclick={() => delete editing[m.id]}>Annuleer</button>
              </div>
            {:else}
              <div class="text">
                <span>{m.pinned ? "📌 " : ""}{m.text}</span>
                <span class="faint small">
                  {origin[m.origin]} · {m.certainty}% zeker · {m.uses}× gebruikt · {ago(m.lastUsed)}{m.localOnly ? " · alleen op dit apparaat" : ""} · <code>{m.shortId}</code>
                </span>
              </div>
              <div class="tools">
                <button class="ghost tiny" title={m.pinned ? "Losmaken" : "Vastpinnen: vervaagt nooit"} onclick={() => act(() => brainApi.memoryPin(m.id, !m.pinned))}>{m.pinned ? "Losmaken" : "Pin"}</button>
                <button class="ghost tiny" title="Nooit naar een externe AI" onclick={() => act(() => brainApi.memoryLocalOnly(m.id, !m.localOnly))}>{m.localOnly ? "Mag mee" : "🔒"}</button>
                <button class="ghost tiny" onclick={() => (editing[m.id] = m.text)}>Aanpassen</button>
                <button class="ghost tiny danger" onclick={() => act(() => brainApi.memoryDelete(m.id))}>Vergeet</button>
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  {/each}

  <h3>Gewoontes</h3>
  <p class="faint note">Nook kent {overview.learnedWords} woorden uit je vragen en welke bronnen daarbij hielpen. Dat blijft op deze computer.</p>

  {#if overview.importable.length}
    <h3>Importeren</h3>
    <div class="group">
      {#each overview.importable as [path, count] (path)}
        <div class="row">
          <span>Kennisgraaf van de MCP-geheugenserver<br /><span class="faint small">{path} · {count} items</span></span>
          <button onclick={() => importGraph(path)}>Importeer</button>
        </div>
      {/each}
    </div>
    {#if imported}<p class="faint note">{imported}</p>{/if}
  {/if}

  {#if overview.items.length}
    <div class="clear">
      {#if confirmClear}
        <span>Alles vergeten? Dit kan niet ongedaan.</span>
        <button class="ghost" onclick={() => (confirmClear = false)}>Annuleer</button>
        <button class="danger" onclick={() => act(async () => { await brainApi.memoryClear(); confirmClear = false; })}>Alles vergeten</button>
      {:else}
        <button class="ghost danger" onclick={() => (confirmClear = true)}>Alles vergeten…</button>
      {/if}
    </div>
  {/if}
{/if}

<style>
  .small { font-size: 11px; }
  .add { display: flex; gap: 8px; margin-top: 14px; }
  .add input, .grow { flex: 1; }
  .search { width: 100%; margin-top: 12px; }
  .list { padding: 0 14px; }
  .item { display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: 8px 0; border-bottom: 1px solid var(--line); }
  .item:last-child { border-bottom: none; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; user-select: text; }
  .tools { display: flex; gap: 2px; flex-shrink: 0; }
  .tiny { padding: 2px 7px; font-size: 11px; }
  .danger { color: var(--coral); }
  .clear { display: flex; gap: 8px; align-items: center; justify-content: flex-end; margin-top: 20px; font-size: 12px; }
</style>
