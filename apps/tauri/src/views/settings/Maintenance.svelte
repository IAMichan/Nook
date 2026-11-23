<script lang="ts">
  import Energy from "./Energy.svelte";
  // Settings › Maintenance (`SettingsView+Maintenance` and `UpdateSettingsSection` on the Mac), for Windows and Linux:
  // updates (check, channel, install and what is new), the data folder, caches, exporting and resetting the settings,
  // and the versions. Nook's own setup and the AppImage update themselves; an .msi or .deb links to the release.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { invoke } from "@tauri-apps/api/core";
  import { workspaceApi, type WorkspaceSettings } from "../../lib/workspace/api";
  import { api } from "../../lib/api";
  import { nook, relativeTime } from "../../lib/state.svelte";
  import type { Settings } from "../../lib/types";
  import Segmented from "./Segmented.svelte";
  import { STEPS, startUpdates, updater, updates, type UpdateChannel, type UpdateStep } from "../../lib/updates.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { LINKS, maintenance, readableSize, type MaintenanceInfo } from "../../lib/maintenance";

  type OtlpSignal = "traces" | "metrics" | "logs";
  type OtlpProtocol = "http/protobuf" | "http/json";
  interface TelemetrySettings {
    enabled: boolean;
    tracesEndpoint: string;
    metricsEndpoint: string;
    logsEndpoint: string;
    protocol: OtlpProtocol;
  }
  interface TelemetrySignalStatus {
    signal: OtlpSignal;
    endpoint: string | null;
    envVariable: string | null;
  }
  interface TelemetryStatusView {
    signals: TelemetrySignalStatus[];
    protocol: OtlpProtocol;
    protocolEnv: string | null;
    headersEnv: string | null;
    headersCount: number;
    hasSavedHeaders: boolean;
    sdkDisabled: boolean;
  }
  type OtlpTestResult =
    | { kind: "ok"; status: number }
    | { kind: "rejected"; status: number }
    | { kind: "unreachable"; message: string };

  const SIGNALS: OtlpSignal[] = ["traces", "metrics", "logs"];
  const DEFAULT_TELEMETRY: TelemetrySettings = {
    enabled: false,
    tracesEndpoint: "",
    metricsEndpoint: "",
    logsEndpoint: "",
    protocol: "http/protobuf",
  };

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

  // Diagnostics (`settings.maintenance.diagnostics` on the Mac): keeping agent traffic is a workspace setting; the
  // report is made by the backend (`diagnostics_report`), redacted, and only copied.
  let ws = $state<WorkspaceSettings | null>(null);
  $effect(() => {
    if (desktop) workspaceApi.overview().then((o) => (ws = o.settings)).catch(() => {});
  });
  async function setTraffic(on: boolean) {
    if (!ws) return;
    ws = { ...ws, keepTraffic: on };
    await workspaceApi.saveSettings($state.snapshot(ws)).catch((e) => toast.error(tr("Kon het niet bewaren", "Could not save it"), e));
  }
  async function copyDiagnostics() {
    try {
      await navigator.clipboard.writeText(await invoke<string>("diagnostics_report"));
      toast.success(tr("Diagnose gekopieerd", "Diagnostics copied"));
    } catch (e) {
      toast.error(tr("Kopiëren mislukt", "Could not copy"), e);
    }
  }
  async function showLogs() {
    await invoke("diagnostics_show_logs").catch((e) => toast.error(tr("Kon de map niet openen", "Could not open the folder"), e));
  }

  // OpenTelemetry export (`TelemetrySettingsSection` on the Mac)
  const storedTelemetry = $derived<TelemetrySettings>({
    ...DEFAULT_TELEMETRY,
    ...((nook.settings as unknown as { telemetry?: Partial<TelemetrySettings> } | null)?.telemetry ?? {}),
  });
  let otlpStatus = $state<TelemetryStatusView | null>(null);
  let otlpDrafts = $state<Record<OtlpSignal, string>>({ traces: "", metrics: "", logs: "" });
  let otlpHeadersDraft = $state("");
  let otlpTesting = $state<Record<OtlpSignal, boolean>>({ traces: false, metrics: false, logs: false });
  let otlpResults = $state<Partial<Record<OtlpSignal, { ok: boolean; message: string }>>>({});
  let otlpInitialized = false;

  async function refreshTelemetryStatus() {
    if (!desktop) return;
    otlpStatus = await invoke<TelemetryStatusView>("telemetry_status").catch(() => null);
  }

  $effect(() => {
    const t = storedTelemetry;
    if (!otlpInitialized && nook.settings) {
      otlpDrafts = { traces: t.tracesEndpoint, metrics: t.metricsEndpoint, logs: t.logsEndpoint };
      otlpInitialized = true;
    }
  });
  $effect(() => {
    if (desktop) refreshTelemetryStatus();
  });

  function isHttpUrl(raw: string): boolean {
    const trimmed = raw.trim();
    if (!trimmed) return false;
    try {
      const u = new URL(trimmed);
      return (u.protocol === "http:" || u.protocol === "https:") && !!u.hostname;
    } catch {
      return false;
    }
  }

  function signalLabel(s: OtlpSignal): string {
    return s === "traces" ? tr("Traces", "Traces") : s === "metrics" ? tr("Metrics", "Metrics") : tr("Logs", "Logs");
  }

  function signalStatus(s: OtlpSignal): TelemetrySignalStatus | undefined {
    return otlpStatus?.signals.find((item) => item.signal === s);
  }

  async function saveTelemetry(patch: Partial<TelemetrySettings>) {
    const next: TelemetrySettings = { ...storedTelemetry, ...patch };
    await nook.saveSettings({ telemetry: next } as unknown as Partial<Settings>);
    await refreshTelemetryStatus();
  }

  async function saveEndpoint(signal: OtlpSignal) {
    const text = otlpDrafts[signal].trim();
    if (text && !isHttpUrl(text)) {
      otlpResults = { ...otlpResults, [signal]: { ok: false, message: tr("Vul een http- of https-adres in.", "Enter an http or https address.") } };
      return;
    }
    const key = signal === "traces" ? "tracesEndpoint" : signal === "metrics" ? "metricsEndpoint" : "logsEndpoint";
    otlpDrafts[signal] = text;
    // As on the Mac there is no separate switch: a filled-in endpoint is the export being on.
    const others = SIGNALS.filter((s) => s !== signal).some((s) => otlpDrafts[s].trim() !== "");
    await saveTelemetry({ [key]: text, enabled: !!text || others });
  }

  async function saveOtlpHeaders() {
    const text = otlpHeadersDraft.trim();
    if (!text) return;
    try {
      await invoke<boolean>("telemetry_save_headers", { headers: text });
      otlpHeadersDraft = "";
      await refreshTelemetryStatus();
    } catch (e) {
      toast.error(tr("De headers konden niet in de kluis van je systeem worden bewaard.", "The headers could not be saved in your system's keychain."), e);
    }
  }

  async function removeOtlpHeaders() {
    try {
      await invoke<boolean>("telemetry_save_headers", { headers: "" });
      await refreshTelemetryStatus();
    } catch (e) {
      toast.error(tr("Kon het niet bewaren", "Could not save it"), e);
    }
  }

  function canTestSignal(signal: OtlpSignal): boolean {
    const sig = signalStatus(signal);
    if (sig?.envVariable) return !!sig.endpoint;
    return isHttpUrl(otlpDrafts[signal]);
  }

  async function testSignal(signal: OtlpSignal) {
    if (otlpTesting[signal] || !canTestSignal(signal)) return;
    const sig = signalStatus(signal);
    const url = sig?.envVariable ? sig.endpoint : otlpDrafts[signal].trim();
    if (!url) return;
    otlpTesting[signal] = true;
    try {
      const res = await invoke<OtlpTestResult>("telemetry_test", { signal, url });
      if (res.kind === "ok") {
        otlpResults = { ...otlpResults, [signal]: { ok: true, message: tr("De ontvanger nam een lege export aan (HTTP {status}).", "The receiver took an empty export (HTTP {status}).", { status: res.status }) } };
      } else if (res.kind === "rejected") {
        otlpResults = { ...otlpResults, [signal]: { ok: false, message: tr("De ontvanger antwoordde HTTP {status}.", "The receiver answered HTTP {status}.", { status: res.status }) } };
      } else {
        otlpResults = { ...otlpResults, [signal]: { ok: false, message: tr("Geen antwoord: {message}", "No answer: {message}", { message: res.message }) } };
      }
    } catch (e) {
      otlpResults = { ...otlpResults, [signal]: { ok: false, message: tr("Geen antwoord: {message}", "No answer: {message}", { message: String(e) }) } };
    } finally {
      otlpTesting[signal] = false;
    }
  }

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
      {:else if update?.phase === "upToDate"}{tr("Je hebt de nieuwste versie.", "You have the newest version.")}{#if update.lastChecked}{" "}{tr("Gecontroleerd {time}.", "Checked {time}.", { time: relativeTime(update.lastChecked) })}{/if}
      {:else if update?.phase === "available" && update.candidate}{tr("Nook {version} staat klaar. Je gegevens en instellingen blijven gewoon staan.", "Nook {version} is ready. Your data and settings stay as they are.", { version: update.candidate.version })}
      {:else if update?.phase === "unavailable" && update.unavailableReason}{update.unavailableReason}
      {:else if !update}{tr("Deze versie werkt zichzelf niet bij. De nieuwste staat op de releasepagina.", "This version does not update itself. The newest one is on the releases page.")}
      {:else}{tr("Nook zoekt zelf naar nieuwe versies en installeert ze met één klik.", "Nook looks for new versions by itself and installs them with one click.")}{/if}
    </small></span>
    <span class="inline">
      <code>{update?.version || info?.version || nook.info?.version || "–"}</code>
      {#if update && update.phase !== "unavailable"}
        <button class="small" disabled={update.checking || update.phase === "installing"} onclick={checkNow}>{tr("Nu controleren", "Check now")}</button>
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
      <input type="checkbox" role="switch" aria-label={tr("Automatisch zoeken", "Check automatically")} checked={update.autoCheck} onchange={(e) => updates.setPrefs({ autoCheck: e.currentTarget.checked })} />
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
<Energy />
{#if desktop}
  <h3>{tr("Diagnose", "Diagnostics")}</h3>
  <div class="group">
    {#if ws}
      <label class="row">
        <span>{tr("Agentverkeer bewaren", "Keep agent traffic")}<br /><small>{tr("Bewaart per sessie wat Nook en de agent elkaar sturen (tot 4 MB per proces), om een fout na te spelen. Het bevat je prompts en de antwoorden en blijft op deze computer, in workspace/provider-traffic; omgevingsvariabelen en sleutels worden nooit opgeslagen.", "Keeps, per session, what Nook and the agent send each other (up to 4 MB per process), to replay a bug. It holds your prompts and the answers and stays on this computer, in workspace/provider-traffic; environment variables and keys are never written.")}</small></span>
        <input type="checkbox" role="switch" checked={!!ws.keepTraffic} onchange={(e) => setTraffic(e.currentTarget.checked)} />
      </label>
    {/if}
    <label class="row">
      <span>{tr("Voorbeelddata tonen (om rond te kijken)", "Show demo data (to explore)")}<br /><small>{tr("Vult Nook met voorbeeldgesprekken, voorbeeldsessies en meldingen zodat je elke functie kunt uitproberen zonder eigen accounts.", "Fills Nook with sample conversations, sample sessions, and notices so you can explore every feature without your own accounts.")}</small></span>
      <input type="checkbox" role="switch" checked={!!nook.settings?.demoData} onchange={(e) => nook.saveSettings({ demoData: e.currentTarget.checked })} />
    </label>
    <div class="row">
      <span>{tr("Diagnose exporteren", "Export diagnostics")}<br /><small>{tr("Kopieert versies, instellingen en het logboek van het afgelopen halfuur, zonder mailadressen, sleutels, telefoonnummers of je naam in paden. Er wordt niets verstuurd.", "Copies versions, set-up facts and the log of the last half hour, without mail addresses, keys, phone numbers or your name in paths. Nothing is sent.")}</small></span>
      <span class="inline"><button class="small" onclick={showLogs}>{tr("Logbestanden tonen", "Show log files")}</button><button class="small" onclick={copyDiagnostics}>{tr("Diagnose kopiëren", "Copy diagnostics")}</button></span>
    </div>
  </div>

  <h3>{tr("OpenTelemetry-export", "OpenTelemetry export")}</h3>
  <p class="section-info">{tr("Stuurt traces, metrics en logs naar een eigen OpenTelemetry-ontvanger (een collector, Grafana, Honeycomb…). Vul per signaal het OTLP HTTP-adres in, bijvoorbeeld http://localhost:4318/v1/traces; een leeg veld stuurt niets. Nook stuurt zijn agentbeurten, geplande taken en opstarttijd, zonder prompts, antwoorden of bestandsinhoud, en geeft de ontvanger door aan elke codeeragent die het start en zelf kan exporteren. Standaard OTEL_EXPORTER_OTLP_*-variabelen in de omgeving van Nook gaan voor deze velden.", "Sends traces, metrics and logs to an OpenTelemetry receiver of your own (a collector, Grafana, Honeycomb…). Enter each signal's OTLP HTTP endpoint, for example http://localhost:4318/v1/traces; an empty field sends nothing. Nook sends its agent turns, scheduled task runs and launch time, without prompts, answers or file contents, and passes the receiver on to every coding agent it starts that can export on its own. Standard OTEL_EXPORTER_OTLP_* variables in Nook's environment override these fields.")}</p>
  <div class="group">
    {#each SIGNALS as signal (signal)}
      {@const sig = signalStatus(signal)}
      {@const envVar = sig?.envVariable ?? null}
      {@const res = otlpResults[signal]}
      <div class="row otlp-row">
        <div class="otlp-main">
          <span class="otlp-label">{signalLabel(signal)}</span>
          <div class="otlp-controls">
            {#if envVar}
              <code class="path">{sig?.endpoint ?? ""}</code>
            {:else}
              <input
                class="otlp-input"
                type="url"
                aria-label={signalLabel(signal)}
                placeholder={`http://localhost:4318/v1/${signal}`}
                value={otlpDrafts[signal]}
                oninput={(e) => { otlpDrafts[signal] = e.currentTarget.value; const next = { ...otlpResults }; delete next[signal]; otlpResults = next; }}
                onblur={() => saveEndpoint(signal)}
                onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); saveEndpoint(signal); } }}
              />
            {/if}
            <button class="small" disabled={otlpTesting[signal] || !canTestSignal(signal)} onclick={() => testSignal(signal)}>
              {otlpTesting[signal] ? tr("Testen…", "Testing…") : tr("Testen", "Test")}
            </button>
          </div>
        </div>
        {#if envVar}
          <small class="faint otlp-note">{tr("Ingesteld door de omgeving ({variable})", "Set by environment ({variable})", { variable: envVar })}</small>
        {/if}
        {#if res}
          <small class="otlp-note" class:otlp-ok={res.ok} class:failure={!res.ok}>{res.message}</small>
        {/if}
      </div>
    {/each}
    <div class="row">
      <span>{tr("Protocol voor agents", "Protocol for agents")}<br /><small>{#if otlpStatus?.protocolEnv}{tr("Ingesteld door de omgeving ({variable})", "Set by environment ({variable})", { variable: otlpStatus.protocolEnv })}{:else}{tr("Hoe agents coderen wat ze sturen. Kies http/json voor ontvangers die geen protobuf aannemen.", "How agents encode what they send. Pick http/json for receivers that do not accept protobuf.")}{/if}</small></span>
      <select
        aria-label={tr("Protocol voor agents", "Protocol for agents")}
        disabled={!!otlpStatus?.protocolEnv}
        value={otlpStatus?.protocolEnv ? otlpStatus.protocol : storedTelemetry.protocol}
        onchange={(e) => saveTelemetry({ protocol: e.currentTarget.value as OtlpProtocol })}
      >
        <option value="http/protobuf">http/protobuf</option>
        <option value="http/json">http/json</option>
      </select>
    </div>
    <div class="row otlp-row">
      {#if otlpStatus?.headersEnv}
        <div class="otlp-main">
          <span class="otlp-label">{tr("Headers", "Headers")}</span>
          <span class="faint">{tr("{n} headers", "{n} headers", { n: otlpStatus.headersCount })}</span>
        </div>
        <small class="faint otlp-note">{tr("Ingesteld door de omgeving ({variable})", "Set by environment ({variable})", { variable: otlpStatus.headersEnv })}</small>
      {:else if otlpStatus?.hasSavedHeaders}
        <div class="otlp-main">
          <span>{tr("Headers", "Headers")}<br /><small>{tr("Bewaard in de kluis van je systeem; gaat mee met elke export.", "Saved in your system's keychain; sent with every export.")}</small></span>
          <button class="small" onclick={removeOtlpHeaders}>{tr("Verwijderen", "Remove")}</button>
        </div>
      {:else}
        <div class="otlp-main">
          <span class="otlp-label">{tr("Headers", "Headers")}</span>
          <div class="otlp-controls">
            <input
              class="otlp-input"
              type="password"
              aria-label={tr("Headers", "Headers")}
              placeholder="Authorization=Bearer …"
              bind:value={otlpHeadersDraft}
              onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); saveOtlpHeaders(); } }}
            />
            <button class="small" disabled={!otlpHeadersDraft.trim()} onclick={saveOtlpHeaders}>{tr("Bewaar", "Save")}</button>
          </div>
        </div>
        <small class="faint otlp-note">{tr("Voor ontvangers die een sleutel vragen: sleutel=waarde, gescheiden door komma's. Bewaard in de kluis van je systeem bij Enter.", "For receivers that need a key: key=value, separated by commas. Saved in your system's keychain on Enter.")}</small>
      {/if}
    </div>
    <p class="note">{tr("Nooks eigen export gebruikt OTLP/HTTP JSON. Agents gebruiken de ontvanger vanaf hun volgende start; sessies op een andere machine niet.", "Nook's own export uses OTLP/HTTP JSON. Agents use the receiver from their next start; sessions on another machine are left out.")}</p>
  </div>
{/if}
<h3>{tr("Gegevens", "Data")}</h3>
<div class="group">
  <div class="row">
    <span>{tr("Gegevensmap", "Data folder")}<br /><small class="faint path">{info?.dataFolder ?? ""}</small></span>
    {#if desktop}<button class="small" onclick={openFolder}>{tr("Openen", "Open")}</button>{/if}
  </div>
  <div class="row">
    <span>{tr("Caches", "Caches")}<br /><small class="faint">{tr("Iconen van diensten en korte geluidsbestanden. Nook haalt ze zelf weer op als het nodig is.", "Service icons and short-lived audio files. Nook fetches them again when needed.")}</small></span>
    <span class="inline"><span class="faint">{info?.cacheBytes != null ? readableSize(info.cacheBytes) : ""}</span><button class="small" disabled={!info?.cacheBytes} onclick={clearCaches}>{tr("Legen", "Clear")}</button></span>
  </div>
</div>
<h3>{tr("Instellingen", "Settings")}</h3>
<div class="group">
  {#if desktop}
    <div class="row">
      <span>{tr("Exporteren", "Export")}<br /><small class="faint">{tr("Alle instellingen als één bestand. Sleutels en wachtwoorden staan er niet in: die blijven in de beveiligde opslag van je computer.", "All settings as one file. Keys and passwords are not in it: they stay in your computer's secure storage.")}</small></span>
      <button class="small" onclick={exportSettings}>{tr("Exporteren…", "Export…")}</button>
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
      <button class="small" onclick={() => (confirmReset = true)}>{tr("Terugzetten…", "Restore…")}</button>
    {/if}
  </div>
</div>
<h3>{tr("Versies", "Versions")}</h3>
<div class="group">
  <pre class="versions">{versions}</pre>
  <div class="row"><span class="faint">{tr("Handig om mee te sturen als je een probleem meldt.", "Useful to include when you report a problem.")}</span><button class="small" onclick={copyVersions}>{copied ? tr("Gekopieerd", "Copied") : tr("Kopiëren", "Copy")}</button></div>
</div>

<style>
  small { font: var(--text-detail); line-height: 1.3; color: var(--text2); display: inline-block; }
  .path { font: var(--text-code); word-break: break-all; user-select: text; }
  code { font: var(--text-code); color: var(--text2); }
  ul { margin: var(--space-8) 0 0; padding-left: var(--space-16); font: var(--text-detail); color: var(--text2); }
  .steps { justify-content: flex-start; gap: var(--space-12); }
  .step { font: var(--text-detail); color: var(--text3); flex: none !important; }
  .step.done { color: var(--text2); }
  .step.now { color: var(--paper); }
  .failure { color: var(--coral); }
  .versions { font: var(--text-code); color: var(--text2); margin: 0; padding: var(--space-16) 0 var(--space-8); white-space: pre-wrap; user-select: text; }
  .otlp-row { flex-direction: column; align-items: stretch; gap: var(--space-6); }
  .otlp-main { display: flex; align-items: center; justify-content: space-between; gap: var(--space-12); width: 100%; }
  .otlp-label { flex: none; color: var(--paper); font: var(--text-body); }
  .otlp-controls { display: flex; align-items: center; gap: var(--space-8); flex: 1; justify-content: flex-end; min-width: 0; }
  .otlp-input { flex: 0 1 230px; min-width: 140px; font: var(--text-body); }
  .otlp-note { margin: 0; }
  .otlp-ok { color: var(--mint); }
</style>
