<script lang="ts">
  // Settings › Maintenance (`SettingsView+Maintenance` and `UpdateSettingsSection` on the Mac), for Windows and Linux:
  // updates (check, channel, install and what is new), the data folder, caches, exporting and resetting the settings,
  // and the versions. Nook's own setup and the AppImage update themselves; an .msi or .deb links to the release.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import { nook, relativeTime } from "../../lib/state.svelte";
  import OnOffSwitch from "../../components/OnOffSwitch.svelte";
  import Segmented from "./Segmented.svelte";
  import { STEPS, startUpdates, updater, updates, type UpdateChannel, type UpdateStep } from "../../lib/updates.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { LINKS, maintenance, readableSize, type MaintenanceInfo } from "../../lib/maintenance";

  const desktop = $derived(!!nook.info?.capabilities.desktop);
  let info = $state<MaintenanceInfo | null>(null);
  let confirmReset = $state(false);
  let copied = $state(false);
  startUpdates();
  const update = $derived(updater.status);
  const stepLabel = (step: UpdateStep) => ({
    download: tr("Downloaden", "Download"),
    verify: tr("Handtekening controleren", "Check the signature"),
    install: tr("Installeren", "Install"),
    restart: tr("Opnieuw starten", "Restart"),
  })[step];
  const channels = $derived([
    { value: "stable" as UpdateChannel, label: tr("Stabiel", "Stable") },
    { value: "beta" as UpdateChannel, label: tr("Bèta", "Beta") },
  ]);

  /// What Install does for the way Nook was installed.
  const installNote = $derived(({
    windowsSetup: tr("Nook sluit even af, installeert de update met een voortgangsvenster en start dan vanzelf weer. Lopende agents stoppen en kun je daarna hervatten.", "Nook closes for a moment, installs the update with a progress window, and starts again by itself. Running agents stop and can be resumed afterwards."),
    windowsMsi: tr("Windows vraagt om beheerdersrechten, installeert de update met een voortgangsvenster en start Nook dan vanzelf weer. Lopende agents stoppen en kun je daarna hervatten.", "Windows asks for administrator rights, installs the update with a progress window, and starts Nook again by itself. Running agents stop and can be resumed afterwards."),
    deb: tr("Je systeem vraagt om je wachtwoord om het pakket bij te werken; daarna start Nook vanzelf weer. Lopende agents stoppen en kun je daarna hervatten.", "Your system asks for your password to update the package; then Nook starts again by itself. Running agents stop and can be resumed afterwards."),
  } as Record<string, string>)[update?.installKind.kind ?? ""] ?? tr("Nook vervangt de AppImage en start dan vanzelf weer. Lopende agents stoppen en kun je daarna hervatten.", "Nook replaces the AppImage and starts again by itself. Running agents stop and can be resumed afterwards."));

  async function checkNow() {
    await updates.check().catch((e) => toast.error(tr("Kon niet naar updates zoeken", "Could not check for updates"), e));
  }

  async function installUpdate() {
    // On success Nook quits and the setup starts the new version; a failure shows in the panel.
    await updates.install().catch(() => {});
  }

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
      nook.info = await api.appInfo();
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

<h3>{tr("Updates", "Updates")}</h3>
<div class="group">
  <div class="row">
    <span>{tr("Versie", "Version")}<br /><small class="faint">
      {#if update?.phase === "checking" || update?.checking}{tr("Zoeken naar updates…", "Checking for updates…")}
      {:else if update?.phase === "upToDate"}{tr("Je hebt de nieuwste versie.", "You have the newest version.")}{#if update.lastChecked} {tr("Gecontroleerd {time}.", "Checked {time}.", { time: relativeTime(update.lastChecked) })}{/if}
      {:else if update?.phase === "available" && update.candidate}{tr("Nook {version} staat klaar. Je gegevens en instellingen blijven gewoon staan.", "Nook {version} is ready. Your data and settings stay as they are.", { version: update.candidate.version })}
      {:else if update?.phase === "unavailable" && update.unavailableReason}{update.unavailableReason}
      {:else if !update}{tr("Deze versie werkt zichzelf niet bij. De nieuwste staat op de releasepagina.", "This version does not update itself. The newest one is on the releases page.")}
      {:else}{tr("Nook zoekt zelf naar nieuwe versies en installeert ze met één klik.", "Nook looks for new versions by itself and installs them with one click.")}{/if}
    </small></span>
    <span class="inline">
      <code>{update?.version || info?.version || nook.info?.version || "–"}</code>
      {#if update && update.phase !== "unavailable"}
        <button disabled={update.checking || update.phase === "installing"} onclick={checkNow}>{tr("Nu controleren", "Check now")}</button>
      {:else}
        <button onclick={() => openUrl(LINKS.releases)}>{tr("Releasepagina", "Releases page")}</button>
      {/if}
    </span>
  </div>
  {#if update?.problem && update.phase !== "unavailable"}
    <div class="row"><small class="faint">{tr("Laatste controle mislukt: {problem}", "The last check failed: {problem}", { problem: update.problem })}</small></div>
  {/if}
  {#if update?.manual}
    <div class="row">
      <span>{tr("Nook {version} is uit", "Nook {version} is out", { version: update.manual.version })}<br /><small class="faint">{tr("Download hem één keer zelf; daarna werkt Nook zichzelf bij.", "Download it yourself once; after that Nook updates itself.")}</small></span>
      <button onclick={() => openUrl(update.manual?.page ?? LINKS.releases)}>{tr("Downloaden", "Download")}</button>
    </div>
  {/if}
  {#if update?.phase === "readyToRestart"}
    <div class="row">
      <span>{tr("Klaar om te herstarten", "Ready to restart")}<br /><small class="faint">{tr("De update is gedownload en gecontroleerd. Er werken nog agents: bij het herstarten stoppen ze, en daarna kun je ze hervatten.", "The update is downloaded and checked. Agents are still working: they stop when Nook restarts, and you can resume them afterwards.")}</small></span>
      <button class="primary" onclick={() => updates.restart().catch(() => {})}>{tr("Nu herstarten", "Restart now")}</button>
    </div>
  {/if}
  {#if update?.candidate && (update.phase === "available" || update.phase === "installing" || update.phase === "failed")}
    {@const candidate = update.candidate}
    <div class="row">
      <span>{candidate.title}<br /><small class="faint">{installNote}</small></span>
      <span class="inline">
        {#if candidate.page}<button class="ghost" onclick={() => openUrl(candidate.page ?? LINKS.releases)}>{tr("Release-opmerkingen", "Release notes")}</button>{/if}
        <button class="primary" disabled={update.phase === "installing"} onclick={installUpdate}>
          {update.phase === "installing" ? tr("Bijwerken…", "Updating…") : update.phase === "failed" ? tr("Opnieuw proberen", "Try again") : tr("Installeren en herstarten", "Install and restart")}
        </button>
      </span>
    </div>
    {#if update.phase === "installing"}
      <div class="row steps">
        {#each STEPS as step, i (step)}
          {@const current = update.step ? STEPS.indexOf(update.step) : 0}
          <span class="step" class:done={i < current} class:now={i === current}>{stepLabel(step)}{#if step === "download" && i === current && update.progress != null} {Math.round(update.progress * 100)}%{/if}</span>
        {/each}
      </div>
    {/if}
    {#if candidate.changes.length}
      <div class="row changes">
        <span>{tr("Wat er nieuw is", "What's new")}
          <ul>{#each candidate.changes.slice(0, 12) as change (change.pullRequest)}<li>{change.title}</li>{/each}</ul>
          {#if candidate.changeCount > 12}<small class="faint">{tr("En nog {n}.", "And {n} more.", { n: candidate.changeCount - 12 })}</small>{/if}
        </span>
      </div>
    {/if}
  {/if}
  {#if update?.phase === "failed" && update.failure}
    <div class="row">
      <span class="failure">{tr("Update mislukt", "Update failed")}<br /><small class="faint">{update.failure}</small></span>
      <button onclick={() => updates.dismiss()}>{tr("Sluiten", "Close")}</button>
    </div>
  {/if}
  {#if update?.receipt}
    <div class="row changes">
      <span>{tr("Bijgewerkt van {from} naar {to}", "Updated from {from} to {to}", { from: update.receipt.from, to: update.receipt.to })}
        {#if update.receipt.changes.length}<ul>{#each update.receipt.changes.slice(0, 12) as change (change.pullRequest)}<li>{change.title}</li>{/each}</ul>{/if}
      </span>
      <button onclick={() => updates.dismiss()}>{tr("Sluiten", "Close")}</button>
    </div>
  {/if}
  {#if update && update.phase !== "unavailable"}
    <div class="row">
      <span>{tr("Automatisch zoeken", "Check automatically")}<br /><small class="faint">{tr("Een paar keer per uur een kleine vraag aan GitHub. Installeren doe je altijd zelf.", "A small question to GitHub a few times an hour. Installing is always your click.")}</small></span>
      <OnOffSwitch on={update.autoCheck} label={tr("Automatisch zoeken", "Check automatically")} onchange={(v) => updates.setPrefs({ autoCheck: v })} />
    </div>
    <div class="row">
      <span>{tr("Kanaal", "Channel")}<br /><small class="faint">{tr("Bèta krijgt nieuwe versies eerder. Nook gaat nooit terug naar een oudere versie.", "Beta gets new versions earlier. Nook never goes back to an older version.")}</small></span>
      {#if update.policy.betaDisabled}
        <small class="faint">{tr("Je beheerder houdt Nook op het stabiele kanaal.", "Your administrator keeps Nook on the Stable channel.")}</small>
      {:else}
        <Segmented options={channels} value={update.channel} label={tr("Kanaal", "Channel")} onchange={(v) => updates.setPrefs({ channel: v })} />
      {/if}
    </div>
  {/if}
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
      <span>{tr("Exporteren", "Export")}<br /><small class="faint">{tr("Alle instellingen als één bestand. Sleutels en wachtwoorden staan er niet in: die blijven in de beveiligde opslag van je computer.", "All settings as one file. Keys and passwords are not in it: they stay in your computer's secure storage.")}</small></span>
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
  ul { margin: var(--space-8) 0 0; padding-left: var(--space-16); font: var(--text-detail); color: var(--text2); }
  .steps { justify-content: flex-start; gap: var(--space-12); }
  .step { font: var(--text-detail); color: var(--text3); flex: none !important; }
  .step.done { color: var(--text2); }
  .step.now { color: var(--paper); }
  .failure { color: var(--coral); }
  .versions { font: var(--text-code); color: var(--text2); margin: 0; padding: var(--space-16) 0 var(--space-8); white-space: pre-wrap; user-select: text; }
</style>
