<script lang="ts">
  // Settings › Maintenance (`SettingsView+Maintenance` and `UpdateSettingsSection` on the Mac), for Windows and Linux:
  // the data folder, caches, exporting and resetting the settings, the versions, and where updates come from. This
  // build has no updater of its own, so the newest version is on the releases page.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { LINKS, maintenance, readableSize, type MaintenanceInfo } from "../../lib/maintenance";

  const desktop = $derived(!!nook.info?.capabilities.desktop);
  let info = $state<MaintenanceInfo | null>(null);
  let confirmReset = $state(false);
  let copied = $state(false);
  const load = () => maintenance.info().then((v) => (info = v)).catch(() => {});
  $effect(() => {
    load();
  });

  async function openFolder() {
    await maintenance.openDataFolder().catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e));
  }

  async function clearCaches() {
    try {
      const freed = await maintenance.clearCaches();
      toast.success(tr("{size} vrijgemaakt", "{size} freed", { size: readableSize(freed) }));
      await load();
    } catch (e) {
      toast.error(tr("Kon de caches niet legen", "Could not clear the caches"), e);
    }
  }

  async function exportSettings() {
    try {
      const path = await maintenance.exportSettings();
      if (path) toast.success(tr("Instellingen bewaard in {path}", "Settings saved to {path}", { path }));
    } catch (e) {
      toast.error(tr("Kon de instellingen niet exporteren", "Could not export the settings"), e);
    }
  }

  async function reset() {
    confirmReset = false;
    try {
      nook.settings = await maintenance.resetSettings();
      nook.info = await import("../../lib/api").then((m) => m.api.appInfo());
      toast.success(tr("Instellingen teruggezet", "Settings restored"));
    } catch (e) {
      toast.error(tr("Kon de instellingen niet terugzetten", "Could not restore the settings"), e);
    }
  }

  const versions = $derived(info ? [
    `Nook ${info.version}`,
    `${info.os} ${info.arch}`,
    `Tauri ${info.tauriVersion}`,
    ...(info.webviewVersion ? [`WebView ${info.webviewVersion}`] : []),
    `${tr("Taal", "Language")} ${nook.settings?.appLanguage ?? ""}`,
  ].join("\n") : "");

  async function copyVersions() {
    try {
      await navigator.clipboard.writeText(versions);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch (e) {
      toast.error(tr("Kopiëren mislukt", "Could not copy"), e);
    }
  }
</script>

<h2>{tr("Onderhoud", "Maintenance")}</h2>
<h3>{tr("Updates", "Updates")}</h3>
<div class="group">
  <div class="row">
    <span>{tr("Versie", "Version")}<br /><small class="faint">{tr("Deze versie werkt zichzelf nog niet bij. De nieuwste staat op de releasepagina.", "This version does not update itself yet. The newest one is on the releases page.")}</small></span>
    <span class="inline"><code>{info?.version ?? nook.info?.version ?? "–"}</code><button onclick={() => openUrl(LINKS.releases)}>{tr("Zoek naar updates", "Check for updates")}</button></span>
  </div>
</div>
<h3>{tr("Gegevens", "Data")}</h3>
<div class="group">
  <div class="row">
    <span>{tr("Gegevensmap", "Data folder")}<br /><small class="faint path">{info?.dataFolder ?? ""}</small></span>
    {#if desktop}<button onclick={openFolder}>{tr("Openen", "Open")}</button>{/if}
  </div>
  <div class="row">
    <span>{tr("Caches", "Caches")}<br /><small class="faint">{tr("Iconen van diensten en korte geluidsbestanden. Nook haalt ze zelf weer op als het nodig is.", "Service icons and short-lived audio files. Nook fetches them again when needed.")}</small></span>
    <span class="inline"><span class="faint">{info ? readableSize(info.cacheBytes) : ""}</span><button disabled={!info || info.cacheBytes === 0} onclick={clearCaches}>{tr("Legen", "Clear")}</button></span>
  </div>
</div>
<h3>{tr("Instellingen", "Settings")}</h3>
<div class="group">
  {#if desktop}
    <div class="row">
      <span>{tr("Exporteren", "Export")}<br /><small class="faint">{tr("Alle instellingen als één bestand. Sleutels en wachtwoorden staan er niet in: die blijven in de sleutelbos van je computer.", "All settings as one file. Keys and passwords are not in it: they stay in your computer's keychain.")}</small></span>
      <button onclick={exportSettings}>{tr("Exporteren…", "Export…")}</button>
    </div>
  {/if}
  <div class="row">
    <span>{tr("Standaardinstellingen", "Default settings")}<br /><small class="faint">{tr("Zet alles terug zoals bij de eerste start. Je taal, je gesprekken, je geheugen, je koppelingen en je sleutels blijven.", "Puts everything back as on the first start. Your language, conversations, memory, connections and keys stay.")}</small></span>
    {#if confirmReset}
      <span class="inline">
        <button class="ghost" onclick={() => (confirmReset = false)}>{tr("Annuleren", "Cancel")}</button>
        <button class="danger" onclick={reset}>{tr("Terugzetten", "Restore")}</button>
      </span>
    {:else}
      <button onclick={() => (confirmReset = true)}>{tr("Terugzetten…", "Restore…")}</button>
    {/if}
  </div>
</div>
<h3>{tr("Versies", "Versions")}</h3>
<div class="group">
  <pre class="versions">{versions}</pre>
  <div class="row"><span class="faint">{tr("Handig om mee te sturen als je een probleem meldt.", "Useful to include when you report a problem.")}</span><button onclick={copyVersions}>{copied ? tr("Gekopieerd", "Copied") : tr("Kopiëren", "Copy")}</button></div>
</div>

<style>
  small { font: var(--text-detail); color: var(--text3); display: inline-block; max-width: 480px; }
  .path { font: var(--text-code); font-size: 11.5px; word-break: break-all; user-select: text; }
  code { font: var(--text-code); color: var(--text2); }
  .versions { font: var(--text-code); color: var(--text2); margin: 0; padding: var(--space-16) 0 var(--space-8); white-space: pre-wrap; user-select: text; }
</style>
