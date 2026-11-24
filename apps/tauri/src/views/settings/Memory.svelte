<script lang="ts">
  // Geheugen: wat Nook over je weet, waar het vandaan komt en hoe zeker hij is. Alles is hier te zien, aan te passen,
  // vast te pinnen, op dit apparaat te houden of te vergeten. Nook leert alleen zelf als "Leer zelf" aan staat.
  import { brainApi, type MemoryItem, type MemoryOverview } from "../../lib/brain";
  import { connectorsApi } from "../../lib/connectors";
  import { nook } from "../../lib/state.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import { tip } from "../../components/ui/tip";

  const s = $derived(nook.settings!);
  let overview = $state<MemoryOverview | null>(null);
  let query = $state("");
  let adding = $state("");
  let editing = $state<Record<string, string>>({});
  let error = $state<string | null>(null);
  let imported = $state<number | null>(null);

  async function refresh() {
    overview = await brainApi.memory();
  }

  $effect(() => {
    refresh();
  });

  const kinds: { id: MemoryItem["kind"]; title: string }[] = $derived([
    { id: "fact", title: tr("Over jou", "About you") },
    { id: "preference", title: tr("Voorkeuren", "Preferences") },
    { id: "lesson", title: tr("Geleerd", "Learned") },
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
      imported = (imported ?? 0) + (await brainApi.memoryImport(path));
    });
  }
</script>

<!-- The Mac's Memory (`MemorySettingsSection`): its two switches under "Nook remembers and learns", then what it
     remembers with a field to add one, the learned sources with Forget everything, and the import last. -->
<h3>{tr("Nook onthoudt en leert", "Nook remembers and learns")}</h3>
<p class="section-info">{tr("Ingebouwd. Nook onthoudt wat je vertelt en leert van je correcties, dus weet de volgende keer nog wie Lisa is. Blijft op deze computer.", "Built in. Nook remembers what you tell it and learns from your corrections, so it still knows who Lisa is next time. Stays on this computer.")}</p>
<div class="group">
  <label class="row">
    <span>{tr("Gebruik mijn geheugen", "Use my memory")}<br /><small>{tr("Bij elke vraag gaan alleen de herinneringen mee die erbij horen. Zeg \"onthoud dat…\" of \"vergeet…\" in de chat.", "Each question only takes along the memories that belong to it. Say \"remember that…\" or \"forget…\" in the chat.")}</small></span>
    <input type="checkbox" role="switch" checked={s.useMemory} onchange={(e) => nook.saveSettings({ useMemory: e.currentTarget.checked })} />
  </label>
  <label class="row">
    <span>{tr("Leer vanzelf", "Learn by itself")}<br /><small>{tr("Na een correctie of een paar vragen bewaart Nook wat het onthouden waard is uit wat jij schreef, zoals de agenda die je meestal kiest.", "After a correction or a few questions, Nook keeps what is worth remembering from what you wrote, like the calendar you usually pick.")}</small></span>
    <input type="checkbox" role="switch" checked={s.learnFromChats} disabled={!s.useMemory} onchange={(e) => nook.saveSettings({ learnFromChats: e.currentTarget.checked })} />
  </label>
  {#if overview?.localOnlySource}
    <p class="note lock-note"><Ico name="lock" size={12} />{tr("Geheugen staat bij Privacy op \"alleen op dit apparaat\": een externe AI krijgt het niet.", "Memory is set to \"only on this device\" under Privacy: an external AI doesn't get it.")}</p>
  {/if}
</div>

<h3>{tr("Wat Nook onthoudt ({n})", "What Nook remembers ({n})", { n: overview?.items.length ?? 0 })}</h3>
<div class="group">
  <div class="row add">
    <input placeholder={tr("Iets wat Nook moet onthouden, bijv. \"Lisa is mijn vrouw\"", "Something Nook should remember, e.g. \"Lisa is my wife\"")} bind:value={adding} onkeydown={(e) => e.key === "Enter" && add()} />
    <button onclick={add} disabled={!adding.trim()}>{tr("Onthoud", "Remember")}</button>
  </div>
  {#if error}<p class="note err">{error}</p>{/if}
  {#if overview}
    {#if overview.items.length > 6}
      <label class="row search"><Ico name="search" size={13} /><input placeholder={tr("Zoek in je geheugen", "Search your memory")} bind:value={query} /></label>
    {/if}
    {#if !filtered.length}
      <p class="note">{overview.items.length ? tr("Niets gevonden.", "Nothing found.") : tr("Nook onthoudt nog niets. Zeg in de chat \"onthoud dat…\" of zet Leer vanzelf aan.", "Nook does not remember anything yet. Say \"remember that…\" in the chat or turn on Learn by itself.")}</p>
    {/if}
    {#each kinds as kind (kind.id)}
      {@const items = filtered.filter((m) => m.kind === kind.id)}
      {#if items.length}
        <div class="kind">{kind.title}</div>
        {#each items as m (m.id)}
          <div class="row item" class:editing={editing[m.id] !== undefined}>
            {#if editing[m.id] !== undefined}
              <input class="grow" bind:value={editing[m.id]} use:focusField onkeydown={(e) => { if (e.key === "Enter") save(m); else if (e.key === "Escape") delete editing[m.id]; }} />
              <span class="tools shown">
                <button class="icon" use:tip={tr("Bewaar", "Save")} onclick={() => save(m)}><Ico name="check" size={14} /></button>
              </span>
            {:else}
              <span class="text">
                <span>{m.text}</span>
                <span class="caption">{origin[m.origin]} · {tr("{n}% zeker", "{n}% sure", { n: m.certainty })} · {tr("{n}× gebruikt", "used {n}×", { n: m.uses })} · {ago(m.lastUsed)} · <code>{m.shortId}</code></span>
              </span>
              <span class="idle">{#if m.pinned}<Ico name="pin" size={11} />{/if}{#if m.localOnly}<Ico name="lock" size={11} />{/if}</span>
              <span class="tools">
                <button class="icon" use:tip={tr("Aanpassen", "Edit")} onclick={() => (editing[m.id] = m.text)}><Ico name="pencil" size={14} /></button>
                <button class="icon" use:tip={m.pinned ? tr("Losmaken", "Unpin") : tr("Vastzetten", "Pin")} onclick={() => act(() => brainApi.memoryPin(m.id, !m.pinned))}><Ico name={m.pinned ? "pin-off" : "pin"} size={14} /></button>
                <button class="icon" use:tip={m.localOnly ? tr("Mag ook naar een externe AI", "May also go to an external AI") : tr("Alleen op deze computer", "Only on this computer")} onclick={() => act(() => brainApi.memoryLocalOnly(m.id, !m.localOnly))}><Ico name={m.localOnly ? "lock" : "lock-open"} size={14} /></button>
                <ConfirmedButton class="icon" question={tr("{name} verwijderen?", "Remove {name}?", { name: m.text })} confirmTitle={tr("Vergeten", "Forget")} onconfirm={() => act(() => brainApi.memoryDelete(m.id))}><Ico name="trash-2" size={14} /></ConfirmedButton>
              </span>
            {/if}
          </div>
        {/each}
      {/if}
    {/each}
  {/if}
</div>

{#if overview}
  <div class="group">
    <div class="row">
      <span>{tr("Geleerde bronnen", "Learned sources")}</span>
      <span class="value">{tr("{n} woorden gekoppeld aan een bron", "{n} words linked to a source", { n: overview.learnedWords })}</span>
    </div>
    <div class="row">
      <ConfirmedButton class="" question={tr("Alles vergeten?", "Forget everything?")} detail={tr("Nook vergeet alles wat hij onthield en leerde. Dit kun je niet ongedaan maken.", "Nook forgets everything it remembered and learned. This cannot be undone.")}
        confirmTitle={tr("Vergeet alles", "Forget everything")} disabled={!overview.items.length && !overview.learnedWords}
        onconfirm={() => act(() => brainApi.memoryClear())} />
    </div>
  </div>

  <!-- Bringing over the old MCP memory server is needed once, if ever: last, as on the Mac. -->
  {#if overview.importable.length || overview.oldServer || imported !== null}
    <h3>{tr("Van de MCP-geheugenserver", "From the MCP memory server")}</h3>
    <p class="section-info">{tr("Geheugen zit nu in Nook zelf. Wat de oude MCP-server onthield, neem je hier één keer over; daarna kun je die koppeling weghalen.", "Memory is now part of Nook itself. Bring over what the old MCP server remembered once here; after that you can remove that connection.")}</p>
    <div class="group">
      {#each overview.importable as [path, count] (path)}
        <div class="row">
          <span>{tr("Kennisgraaf van de MCP-geheugenserver", "Knowledge graph from the MCP memory server")}<br /><small>{path} · {tr("{n} items", "{n} items", { n: count })}</small></span>
          <button onclick={() => importGraph(path)}>{tr("Importeer", "Import")}</button>
        </div>
      {/each}
      {#if overview.oldServer}
        {@const [serverId, serverName] = overview.oldServer}
        <div class="row">
          <span>{tr("De MCP-geheugenserver {name} is niet meer nodig: Nook onthoudt nu zelf.", "The MCP memory server {name} is no longer needed: Nook remembers by itself now.", { name: serverName })}</span>
          <ConfirmedButton class="" question={tr("{name} verwijderen?", "Remove {name}?", { name: serverName })} confirmTitle={tr("Server weghalen…", "Remove server…")}
            onconfirm={() => act(() => connectorsApi.mcpRemove(serverId))} />
        </div>
      {/if}
      {#if imported !== null}<p class="note ok">{imported === 1 ? tr("1 herinnering geïmporteerd.", "1 memory imported.") : tr("{n} herinneringen geïmporteerd.", "{n} memories imported.", { n: imported })}</p>{/if}
    </div>
  {/if}
{/if}

<style>
  .lock-note { display: flex; align-items: center; gap: var(--space-4); }
  .add, .search { flex-wrap: nowrap; }
  .add input { flex: 1; min-width: 0; }
  .search { justify-content: flex-start; gap: var(--space-6); color: var(--text3); }
  .search input { flex: 1; min-width: 0; padding: 0; border: none; background: none; box-shadow: none; outline: none; color: var(--paper); font: var(--text-body); }
  .kind { font: var(--text-label); color: var(--text3); padding: var(--space-12) 0 0; }
  .item { flex-wrap: nowrap; }
  .item .grow { flex: 1; min-width: 0; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); user-select: text; }
  .caption { font: var(--text-detail); color: var(--text2); }
  .caption code { font: var(--text-code); font-size: inherit; color: var(--text3); }
  .idle { display: inline-flex; gap: var(--space-4); color: var(--text3); }
  /* What you can do with a memory shows under the pointer (`HoverActionsRow`); a pin and a lock stay at rest. */
  .tools { display: none; gap: var(--space-2); }
  .item:hover .tools, .item:focus-within .tools, .tools.shown { display: inline-flex; }
  .item:hover .idle, .item:focus-within .idle { display: none; }
  .tools :global(.icon) { display: grid; place-items: center; width: 24px; height: 24px; padding: 0; border: none; border-radius: var(--radius-chip); background: none; color: var(--text2); }
  .tools :global(.icon:hover:not(:disabled)) { background: var(--row-hover); color: var(--paper); }
  .value { color: var(--text2); }
  .ok { color: var(--mint) !important; }
</style>
