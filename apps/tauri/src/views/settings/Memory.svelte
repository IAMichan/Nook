<script lang="ts">
  // Geheugen: wat Nook over je weet, waar het vandaan komt en hoe zeker hij is. Alles is hier te zien, aan te passen,
  // vast te pinnen, op dit apparaat te houden of te vergeten. Nook leert alleen zelf als "Leer zelf" aan staat.
  import { brainApi, type MemoryItem, type MemoryOverview } from "../../lib/brain";
  import { nook } from "../../lib/state.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";

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

  const kinds: { id: MemoryItem["kind"]; title: string }[] = $derived([
    { id: "fact", title: tr("Feiten", "Facts") },
    { id: "preference", title: tr("Voorkeuren", "Preferences") },
    { id: "lesson", title: tr("Geleerd van correcties", "Learned from corrections") },
  ]);
  const origin: Record<MemoryItem["origin"], string> = $derived({
    told: tr("verteld", "told"), learned: tr("geleerd", "learned"), observed: tr("gezien", "seen"), imported: tr("geïmporteerd", "imported"),
  });

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
    if (!iso) return tr("nog niet gebruikt", "not used yet");
    return new Date(iso).toLocaleDateString(locale(), { day: "numeric", month: "short", year: "numeric" });
  }

  function importGraph(path: string) {
    act(async () => {
      const n = await brainApi.memoryImport(path);
      imported = n === 1 ? tr("1 herinnering geïmporteerd.", "1 memory imported.") : tr("{n} herinneringen geïmporteerd.", "{n} memories imported.", { n });
    });
  }
</script>

<h2>{tr("Geheugen", "Memory")}</h2>
<p class="muted">{tr("Wat Nook over je weet. Zeg in de chat \"onthoud dat…\" of \"vergeet…\", of pas het hier aan.", "What Nook knows about you. Say \"remember that…\" or \"forget…\" in the chat, or change it here.")}</p>
<div class="group">
  <label class="row"><span>{tr("Gebruik wat Nook weet bij elke vraag", "Use what Nook knows with every question")}</span><input type="checkbox" checked={s.useMemory} onchange={(e) => nook.saveSettings({ useMemory: e.currentTarget.checked })} /></label>
  <label class="row">
    <span>{tr("Leer zelf van gesprekken", "Learn from conversations")}<br /><span class="faint small">{tr("Van je correcties, de plannen die je goedkeurt en de bronnen die je gebruikt.", "From your corrections, the plans you approve and the sources you use.")}</span></span>
    <input type="checkbox" checked={s.learnFromChats} onchange={(e) => nook.saveSettings({ learnFromChats: e.currentTarget.checked })} />
  </label>
</div>
{#if overview?.localOnlySource}
  <p class="faint note">{tr("Geheugen staat bij Privacy op \"alleen op dit apparaat\": een externe AI krijgt het niet.", "Memory is set to \"only on this device\" under Privacy: an external AI doesn't get it.")}</p>
{/if}

<div class="add">
  <input placeholder={tr("Iets toevoegen, bijv. Mijn manager heet Sanne", "Add something, e.g. My manager is called Sanne")} bind:value={adding} onkeydown={(e) => e.key === "Enter" && add()} />
  <button onclick={add} disabled={!adding.trim()}>{tr("Onthoud", "Remember")}</button>
</div>
{#if error}<p class="err">{error}</p>{/if}

{#if overview}
  {#if overview.items.length > 6}
    <input class="search" placeholder={tr("Zoeken in het geheugen…", "Search memory…")} bind:value={query} />
  {/if}
  {#if !overview.items.length}
    <p class="faint note">{tr("Nook weet nog niets over je.", "Nook doesn't know anything about you yet.")}</p>
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
                <button onclick={() => save(m)}>{tr("Bewaar", "Save")}</button>
                <button class="ghost" onclick={() => delete editing[m.id]}>{tr("Annuleer", "Cancel")}</button>
              </div>
            {:else}
              <div class="text">
                <span>{m.pinned ? "📌 " : ""}{m.text}</span>
                <span class="faint small">
                  {origin[m.origin]} · {tr("{n}% zeker", "{n}% sure", { n: m.certainty })} · {tr("{n}× gebruikt", "used {n}×", { n: m.uses })} · {ago(m.lastUsed)}{m.localOnly ? " · " + tr("alleen op dit apparaat", "only on this device") : ""} · <code>{m.shortId}</code>
                </span>
              </div>
              <div class="tools">
                <button class="ghost tiny" title={m.pinned ? tr("Losmaken", "Unpin") : tr("Vastpinnen: vervaagt nooit", "Pin: never fades")} onclick={() => act(() => brainApi.memoryPin(m.id, !m.pinned))}>{m.pinned ? tr("Losmaken", "Unpin") : tr("Pin", "Pin")}</button>
                <button class="ghost tiny" title={tr("Nooit naar een externe AI", "Never to an external AI")} onclick={() => act(() => brainApi.memoryLocalOnly(m.id, !m.localOnly))}>{m.localOnly ? tr("Mag mee", "May be shared") : "🔒"}</button>
                <button class="ghost tiny" onclick={() => (editing[m.id] = m.text)}>{tr("Aanpassen", "Edit")}</button>
                <button class="ghost tiny danger" onclick={() => act(() => brainApi.memoryDelete(m.id))}>{tr("Vergeet", "Forget")}</button>
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  {/each}

  <h3>{tr("Gewoontes", "Habits")}</h3>
  <p class="faint note">{tr("Nook kent {n} woorden uit je vragen en welke bronnen daarbij hielpen. Dat blijft op deze computer.", "Nook knows {n} words from your questions and which sources helped with them. That stays on this computer.", { n: overview.learnedWords })}</p>

  {#if overview.importable.length}
    <h3>{tr("Importeren", "Import")}</h3>
    <div class="group">
      {#each overview.importable as [path, count] (path)}
        <div class="row">
          <span>{tr("Kennisgraaf van de MCP-geheugenserver", "Knowledge graph from the MCP memory server")}<br /><span class="faint small">{path} · {tr("{n} items", "{n} items", { n: count })}</span></span>
          <button onclick={() => importGraph(path)}>{tr("Importeer", "Import")}</button>
        </div>
      {/each}
    </div>
    {#if imported}<p class="faint note">{imported}</p>{/if}
  {/if}

  {#if overview.items.length}
    <div class="clear">
      {#if confirmClear}
        <span>{tr("Alles vergeten? Dit kan niet ongedaan.", "Forget everything? This can't be undone.")}</span>
        <button class="ghost" onclick={() => (confirmClear = false)}>{tr("Annuleer", "Cancel")}</button>
        <button class="danger" onclick={() => act(async () => { await brainApi.memoryClear(); confirmClear = false; })}>{tr("Alles vergeten", "Forget everything")}</button>
      {:else}
        <button class="ghost danger" onclick={() => (confirmClear = true)}>{tr("Alles vergeten…", "Forget everything…")}</button>
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
