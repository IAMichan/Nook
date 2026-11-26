<script lang="ts">
  // General (the Mac's `generalSection`): the language Nook speaks and answers in, and how the session list is laid out.
  // Then the confirmations: quitting from the tray asks while sessions work ("Hold ⌘Q to quit" is the Mac's own). Where
  // Nook shows is under Bar & windows, energy under System, the color under Appearance and the shortcuts under Shortcuts.
  import { nook } from "../../lib/state.svelte";
  import { tr, APP_LANGUAGES, type AppLanguage } from "../../lib/i18n.svelte";
  import { loadAgentsView, onAgentsView, saveAgentsView } from "../../lib/agents-view";
  import SettingFieldRow from "./SettingFieldRow.svelte";
  import SettingsSection from "./SettingsSection.svelte";
  import SettingToggle from "./SettingToggle.svelte";

  const s = $derived(nook.settings!);
  // The session list's layout, the same switches as the Agents tab's filter menu.
  let view = $state(loadAgentsView());
  $effect(() => onAgentsView((next) => (view = next)));
  function setView(patch: Partial<typeof view>) {
    view = { ...view, ...patch };
    saveAgentsView(view);
  }
</script>

<SettingsSection title={tr("Taal", "Language")}>
  <SettingFieldRow title={tr("Taal van de app", "App language")}>
    <select value={s.appLanguage} onchange={(e) => nook.saveSettings({ appLanguage: e.currentTarget.value as AppLanguage })}>
      {#each APP_LANGUAGES as lang (lang.code)}<option value={lang.code}>{lang.name}</option>{/each}
    </select>
  </SettingFieldRow>
  <SettingFieldRow title={tr("Taal van antwoorden", "Answer language")}>
    <select value={s.language} onchange={(e) => nook.saveSettings({ language: e.currentTarget.value })}>
      <option value="auto">{tr("Taal van mijn vraag", "Language of my question")}</option>
      {#each APP_LANGUAGES as lang (lang.code)}<option value={lang.code}>{lang.name}</option>{/each}
    </select>
  </SettingFieldRow>
</SettingsSection>

{#if nook.info?.capabilities.localAgents}
  <SettingsSection title={tr("Sessielijst", "Session list")}>
    <SettingToggle
      title={tr("Groepeer sessies per project", "Group sessions by project")}
      checked={view.projectFolders}
      onchange={(projectFolders) => setView({ projectFolders })}
    />
    <SettingToggle
      title={tr("Toon sessies die aan het werk zijn op een eigen plank", "Show working sessions on their own shelf")}
      checked={view.showWorking}
      onchange={(showWorking) => setView({ showWorking })}
    />
  </SettingsSection>
{/if}

{#if nook.info?.capabilities.desktop}
  <SettingsSection title={tr("Bevestigingen", "Confirmations")}>
    <SettingToggle
      title={tr("Vragen voor stoppen terwijl sessies werken", "Ask before quitting while sessions are working")}
      checked={s.confirmQuit !== false}
      onchange={(confirmQuit) => nook.saveSettings({ confirmQuit })}
    />
  </SettingsSection>
{/if}
