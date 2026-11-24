<script lang="ts">
  // General (the Mac's `generalSection`): the language Nook speaks and answers in, and how the session list is laid out.
  // Then the confirmations: quitting from the tray asks while sessions work ("Hold ⌘Q to quit" is the Mac's own). Where
  // Nook shows is under Bar & windows, energy under System, the color under Appearance and the shortcuts under Shortcuts.
  import { nook } from "../../lib/state.svelte";
  import { tr, APP_LANGUAGES, type AppLanguage } from "../../lib/i18n.svelte";
  import { loadAgentsView, onAgentsView, saveAgentsView } from "../../lib/agents-view";

  const s = $derived(nook.settings!);
  // The session list's layout, the same switches as the Agents tab's filter menu.
  let view = $state(loadAgentsView());
  $effect(() => onAgentsView((next) => (view = next)));
  function setView(patch: Partial<typeof view>) {
    view = { ...view, ...patch };
    saveAgentsView(view);
  }
</script>

<h3>{tr("Taal", "Language")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Taal van de app", "App language")}</span>
    <select value={s.appLanguage} onchange={(e) => nook.saveSettings({ appLanguage: e.currentTarget.value as AppLanguage })}>
      {#each APP_LANGUAGES as lang (lang.code)}<option value={lang.code}>{lang.name}</option>{/each}
    </select>
  </label>
  <label class="row">
    <span>{tr("Taal van antwoorden", "Answer language")}</span>
    <select value={s.language} onchange={(e) => nook.saveSettings({ language: e.currentTarget.value })}>
      <option value="auto">{tr("Taal van mijn vraag", "Language of my question")}</option>
      {#each APP_LANGUAGES as lang (lang.code)}<option value={lang.code}>{lang.name}</option>{/each}
    </select>
  </label>
</div>

{#if nook.info?.capabilities.localAgents}
  <h3>{tr("Sessielijst", "Session list")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Groepeer sessies per project", "Group sessions by project")}</span><input type="checkbox" role="switch" checked={view.projectFolders} onchange={(e) => setView({ projectFolders: e.currentTarget.checked })} /></label>
    <label class="row"><span>{tr("Toon sessies die aan het werk zijn op een eigen plank", "Show working sessions on their own shelf")}</span><input type="checkbox" role="switch" checked={view.showWorking} onchange={(e) => setView({ showWorking: e.currentTarget.checked })} /></label>
  </div>
{/if}

{#if nook.info?.capabilities.desktop}
  <h3>{tr("Bevestigingen", "Confirmations")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Vragen voor stoppen terwijl sessies werken", "Ask before quitting while sessions are working")}</span><input type="checkbox" role="switch" checked={s.confirmQuit !== false} onchange={(e) => nook.saveSettings({ confirmQuit: e.currentTarget.checked })} /></label>
  </div>
{/if}
