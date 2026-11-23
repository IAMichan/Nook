<script lang="ts">
  // Privacy: everything Nook is signed in to (`LinkedAccessSection`, Settings › Privacy › Access on the Mac), and the log
  // of what Nook carried out (`AuditLogSection`). Managing happens on Services; this list only says what Nook can reach.
  import { api } from "../../lib/api";
  import type { AuditEntry } from "../../lib/types";
  import { connectorsApi, connectorEvents, type Overview } from "../../lib/connectors";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import { services } from "../../lib/services";
  import { toast } from "../../lib/toast.svelte";
  import { nook } from "../../lib/state.svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import StatusRow from "./StatusRow.svelte";
  import Segmented from "./Segmented.svelte";
  import Fold from "./Fold.svelte";
  import InfoLabel from "./InfoLabel.svelte";
  import { tip } from "../../components/ui/tip";

  // The Mac's Privacy parts this page has: the privacy level (`level`), what Nook may reach (`access`) and the activity
  // log (`log`).
  let { part = "access" }: { part?: "level" | "access" | "log" } = $props();
  type PrivacyLevel = "open" | "balanced" | "strict";
  const level = $derived<PrivacyLevel>(nook.settings?.privacyLevel ?? "balanced");
  function levelDetail(l: PrivacyLevel) {
    return l === "open"
      ? tr("Alles gaat mee zoals het is: de beste antwoorden. Wachtwoordmanagers en wachtwoordvelden blijven altijd buiten beeld.", "Everything goes as it is: the best answers. Password managers and password fields always stay out of view.")
      : l === "balanced"
        ? tr("Geheimen gaan er eerst uit: wachtwoorden, API-sleutels en tokens, privésleutels, pasnummers, IBAN's en BSN's.", "Secrets are taken out first: passwords, API keys and tokens, private keys, card numbers, IBANs and BSNs.")
        : tr("Ook e-mailadressen en telefoonnummers gaan eruit, en je scherm en klembord blijven op deze computer. Antwoorden kunnen daardoor minder volledig zijn.", "E-mail addresses and phone numbers are taken out too, and your screen and clipboard stay on this computer. Answers can be less complete.");
  }
  // What Nook promises whatever the level, each with its icon and the longer line behind the ⓘ.
  const promises = $derived([
    { icon: "eye-off", title: tr("Schermbeelden nooit", "Never screenshots"), detail: tr("Alleen herkende tekst, en alleen als je iets vraagt.", "Only recognized text, and only when you ask something.") },
    { icon: "key-round", title: tr("Wachtwoorden blijven buiten beeld", "Passwords stay hidden"), detail: tr("Wachtwoordmanagers en verborgen klembord-inhoud worden nooit gelezen.", "Password managers and hidden clipboard contents are never read.") },
    { icon: "hand", title: tr("Niets zonder jouw klik", "Nothing without your click"), detail: tr("Nook verstuurt nooit zelf mail.", "Nook never sends emails automatically.") },
    { icon: "lock", title: tr("Sleutels in de beveiligde opslag van je systeem", "Keys in your system's secure storage"), detail: tr("De sleutels en wachtwoorden die Nook bewaart staan in Windows Referentiebeheer, nooit in een bestand of in wat een AI ziet. De eigen aanmelding van een agent (zoals een Codex-API-sleutel) bewaart die agent zelf.", "The keys and passwords Nook keeps stay in Windows Credential Manager, never in a file or in what an AI sees. An agent's own sign-in (such as a Codex API key) is kept by that agent.") },
  ]);

  interface PermissionItem {
    id: string;
    granted: boolean;
    windowsAllowed?: boolean | null;
    settingsUri?: string;
    recommended?: boolean;
    kind?: "switch" | "note";
  }

  // Windows' privacy & system switches (`SystemPermission` on the Mac), read again when the window comes back or while
  // this page stays open.
  let permissions = $state<PermissionItem[]>([]);
  $effect(() => {
    if (part !== "access") return;
    const read = () =>
      invoke<PermissionItem[]>("permissions_overview")
        .then((p) => (permissions = Array.isArray(p) ? p : []))
        .catch(() => {});
    read();
    window.addEventListener("focus", read);
    const timer = setInterval(read, 3000);
    return () => {
      window.removeEventListener("focus", read);
      clearInterval(timer);
    };
  });

  const switchPermissions = $derived(permissions.filter((p) => p.kind !== "note"));
  const notePermissions = $derived(permissions.filter((p) => p.kind === "note"));

  function permissionTitle(id: string): string {
    switch (id) {
      case "microphone": return tr("Microfoon", "Microphone");
      case "notifications": return tr("Meldingen", "Notifications");
      case "screen": return tr("Scherm en vastleggen", "Screen & capture");
      case "location": return tr("Locatie", "Location");
      case "calendar": return tr("Agenda", "Calendar");
      case "mail": return tr("E-mail", "Mail");
      case "background": return tr("Achtergrond-apps", "Background apps");
      case "startup": return tr("Opstart-apps", "Startup apps");
      default: return id;
    }
  }

  function permissionDetail(p: PermissionItem): string {
    switch (p.id) {
      case "microphone":
        return tr("Om met Nook te praten, te dicteren en gesprekken te noteren.", "To talk to Nook, dictate and take call notes.");
      case "notifications":
        return tr("Voor meldingen van Windows als je die kiest bij Meldingen.", "For Windows notifications when you choose them under Notifications.");
      case "screen":
        return tr("Om je actieve vensters te lezen voor antwoorden, schermcontext en Meedenken.", "To read your active windows for answers, screen context and Think Along.");
      case "location":
        return tr("Optioneel. Windows-locatiemachtigingen gelden voor Windows-apps; Nook gebruikt locatie alleen als je erom vraagt.", "Optional. Windows location privacy applies to Windows apps; Nook only uses location when you ask.");
      case "calendar":
        return tr("Windows-agendamachtigingen gelden voor Windows-apps. Nook leest Google- en Microsoft 365-agenda’s via Diensten.", "Windows calendar privacy applies to Windows apps. Nook reads Google and Microsoft 365 calendars via Services.");
      case "mail":
        return tr("Windows-e-mailmachtigingen gelden voor Windows-apps. Nook leest Gmail- en Outlook-accounts via Diensten.", "Windows email privacy applies to Windows apps. Nook reads Gmail and Outlook accounts via Services.");
      case "background":
        return tr("Laat Nook op de achtergrond in het systeemvak klaarstaan voor sneltoetsen, agents en meldingen.", "Lets Nook stay ready in the system tray for shortcuts, agents and notifications.");
      case "startup":
        return tr("Laat Windows Nook automatisch starten zodra je inlogt.", "Lets Windows launch Nook automatically when you sign in.");
      default:
        return "";
    }
  }

  function openPermission(p: PermissionItem) {
    invoke("permissions_open", { id: p.id }).catch((e) => {
      toast.error(String(e));
    });
  }

  let audit = $state<AuditEntry[]>([]);
  let auditQuery = $state("");
  let overview = $state<Overview | null>(null);
  let cleared = $state(false);

  const neverRead = $derived(nook.settings?.neverReadApps ?? []);
  async function setNeverRead(next: string[]) {
    await nook.saveSettings({ neverReadApps: next });
    // What Nook already read from these apps is dropped at once, not at the next read.
    await services.screenForget().catch(() => {});
  }
  function removeNeverRead(app: string) {
    setNeverRead(neverRead.filter((a) => a !== app));
  }
  async function addNeverRead() {
    const picked = await openDialog({ multiple: true, filters: [{ name: tr("Apps", "Apps"), extensions: ["exe"] }] }).catch(() => null);
    const names = (Array.isArray(picked) ? picked : picked ? [picked] : [])
      .map((p) => (p.split(/[\\/]/).pop() ?? "").replace(/\.exe$/i, "").toLowerCase())
      .filter((n) => n && !neverRead.includes(n));
    if (names.length) await setNeverRead([...neverRead, ...names]);
  }

  $effect(() => {
    api.auditEntries(auditQuery).then((a) => (audit = a));
  });

  $effect(() => {
    const load = () => connectorsApi.overview().then((o) => (overview = o));
    load();
    const un = connectorEvents.onChanged(load);
    return () => {
      un.then((f) => f());
    };
  });

  // One line per thing Nook is signed in to: services with a key or token, services you signed in to, GitLab hosts
  // and your own MCP servers.
  const linked = $derived.by(() => {
    if (!overview) return [];
    const configured = new Set(overview.connectors.filter((c) => c.configured).map((c) => c.id));
    const remoteIds = new Set(overview.remote.map((r) => r.id));
    return [
      ...overview.services.filter((s) => configured.has(s.id) && !remoteIds.has(s.id))
        .map((s) => ({ id: s.id, title: s.title, domain: s.domain || null, detail: s.tagline })),
      ...overview.remote.filter((r) => r.server || configured.has(r.id))
        .map((r) => ({ id: r.id, title: r.name, domain: r.domain, detail: r.tagline })),
      ...overview.gitlab.map((host) => ({ id: `gitlab.${host}`, title: "GitLab", domain: host, detail: host })),
      ...overview.mcp.filter((m) => !m.config.serviceId)
        .map((m) => ({ id: m.config.id, title: m.config.name, domain: null, detail: tr("Je eigen server", "Your own server") })),
    ];
  });

  function manage() {
    localStorage.setItem("settings.section", "accounts");
    api.showMain("settings");
  }
</script>

{#if part === "level"}
  <!-- The Mac's `privacyLevelSection`: one choice, what it means, whether it applies now, then the four promises. -->
  <h3>{tr("Privacyniveau", "Privacy level")}</h3>
  <div class="group">
    <div class="row">
      <InfoLabel label={tr("Wat een AI in de cloud ziet", "What a cloud AI sees")} info={tr("Hoe streng Nook filtert wat hij op je computer verzamelt voordat het naar een extern brein gaat.", "How strictly Nook filters what it gathers on your computer before it goes to an external brain.")} />
      <Segmented label={tr("Wat een AI in de cloud ziet", "What a cloud AI sees")} value={level} onchange={(v) => nook.saveSettings({ privacyLevel: v as PrivacyLevel })}
        options={[{ value: "open", label: tr("Open", "Open") }, { value: "balanced", label: tr("Gebalanceerd", "Balanced") }, { value: "strict", label: tr("Strikt", "Strict") }]} />
    </div>
    <p class="note">{levelDetail(level)}</p>
    {#if nook.info?.brainLocal}<p class="note ok"><Ico name="circle-check" size={12} /> {tr("Je brein draait nu op deze computer: er gaat niets weg, dus er hoeft niets gefilterd te worden.", "Your brain runs on this computer right now: nothing leaves it, so nothing needs filtering.")}</p>{/if}
  </div>
  <Fold title={tr("Wat je computer verlaat", "What leaves your computer")} summary={tr("Vier beloftes die altijd gelden", "Four promises that always apply")}>
    {#each promises as p (p.icon)}
      <div class="row promise"><span class="promise-icon"><Ico name={p.icon} size={15} /></span><span class="promise-title">{p.title}</span><span class="promise-info" use:tip={p.detail}><Ico name="info" size={12} /></span></div>
    {/each}
  </Fold>
{#if nook.info?.capabilities.screenReading}
  <div class="group">
    <div class="row">
      <span>{tr("Schermtekst", "Screen text")}</span>
      <ConfirmedButton class="small" question={tr("Vergeten wat Nook net zag?", "Forget what Nook just saw?")} confirmTitle={tr("Vergeet wat Nook nu zag", "Forget what Nook just saw")}
        onconfirm={async () => { await services.screenForget(); toast.success(tr("Schermtekst vergeten.", "Screen text forgotten.")); }} />
    </div>
  </div>
  <!-- Apps Nook never reads (`neverReadApps` on the Mac): not their screen text, and no suggestions while typing. -->
  <h3>{tr("Apps die Nook nooit leest", "Apps Nook never reads")}</h3>
  <p class="section-info">{tr("Nook leest deze apps nooit en doet er geen suggesties, zoals je bank of een privéchat. Wachtwoordmanagers blijven altijd buiten.", "Nook never reads these apps or suggests text in them, like your bank or a private chat. Password managers are always left out.")}</p>
  <div class="group">
    {#each neverRead as app (app)}
      <div class="row"><span><Ico name="eye-off" size={13} /> {app}</span><button class="small" onclick={() => removeNeverRead(app)}>{tr("Verwijder", "Remove")}</button></div>
    {/each}
    <div class="row"><span></span><button class="small" onclick={addNeverRead}>{tr("App toevoegen…", "Add App…")}</button></div>
  </div>
{/if}
{/if}

{#if part === "access"}
{#if permissions.length}
  <!-- The Mac's Permissions (`SystemPermission`): what Windows lets Nook use, with a check once it may, and one-click
       `ms-settings:` deep links to the exact Windows Settings page. -->
  <h3>{tr("Machtigingen", "Permissions")}</h3>
  <p class="section-info">{tr("Wat Windows Nook laat gebruiken. Elke knop opent direct de juiste pagina in de Windows-instellingen; Nook leest de status opnieuw zodra je terugkomt.", "What Windows lets Nook use. Each button opens the matching page in Windows Settings directly; Nook checks the status again as soon as you come back.")}</p>
  <div class="group">
    {#each switchPermissions as p (p.id)}
      <StatusRow done={p.granted} title={permissionTitle(p.id)} detail={permissionDetail(p)}>
        <button
          use:tip={p.settingsUri
            ? tr("Opent {uri} in de Windows-instellingen.", "Opens {uri} in Windows Settings.", { uri: p.settingsUri })
            : tr("Opent deze pagina in de Windows-instellingen.", "Opens this page in Windows Settings.")}
          class="small"
          onclick={() => openPermission(p)}
        >
          {tr("Open Windows-instellingen", "Open Windows Settings")}
        </button>
      </StatusRow>
    {/each}
  </div>

  {#if notePermissions.length}
    <h3>{tr("Windows-toegang voor locatie, agenda en e-mail", "Windows access for location, calendar & mail")}</h3>
    <p class="section-info">{tr("Deze Windows-schakelaars gelden voor Windows-apps. Voor Google en Microsoft 365 gebruikt Nook je gekoppelde accounts onder Diensten.", "These Windows switches apply to Windows apps. For Google and Microsoft 365, Nook uses your linked accounts under Services.")}</p>
    <div class="group">
      {#each notePermissions as p (p.id)}
        <StatusRow done={p.windowsAllowed ?? true} title={permissionTitle(p.id)} detail={permissionDetail(p)}>
          <button
            use:tip={p.settingsUri
              ? tr("Opent {uri} in de Windows-instellingen.", "Opens {uri} in Windows Settings.", { uri: p.settingsUri })
              : tr("Opent deze pagina in de Windows-instellingen.", "Opens this page in Windows Settings.")}
            class="small"
            onclick={() => openPermission(p)}
          >
            {tr("Open Windows-instellingen", "Open Windows Settings")}
          </button>
        </StatusRow>
      {/each}
    </div>
  {/if}
{/if}

<h3>{tr("Gekoppelde accounts en diensten", "Linked accounts and services")}</h3>
<p class="section-info">{tr("Alles waar Nook bij is ingelogd. Met Beheer open je de koppeling om hem uit te zetten of te verwijderen; verwijderen wist ook de sleutel of het token uit je sleutelhanger.", "Everything Nook is signed in to. Manage opens the link, where you can switch it off or remove it; removing also deletes its key or token from your keychain.")}</p>
<div class="group">
  {#each linked as item (item.id)}
    <div class="row linked">
      <span class="plain">
        <ServiceIcon domain={item.domain} title={item.title} />
        <span class="text">
          <span>{item.title}</span>
          <span class="faint small">{item.detail}</span>
        </span>
      </span>
      <button class="small" onclick={manage}>{tr("Beheer", "Manage")}</button>
    </div>
  {:else}
    <p class="empty-note">{tr("Nog niets gekoppeld.", "Nothing linked yet.")}</p>
  {/each}
</div>

{/if}

{#if part === "log"}
<h3>{tr("Logboek", "Log")}</h3>
<p class="section-info">{tr("Alles wat Nook voor je uitvoert, met wat er gebeurde. Wordt 90 dagen bewaard, alleen op deze computer.", "Everything Nook carries out for you, with what happened. Kept for 90 days, only on this computer.")}</p>
<div class="group">
  <div class="row log-search">
    <Ico name="search" size={13} />
    <input placeholder={tr("Zoek in het logboek", "Search the log")} bind:value={auditQuery} aria-label={tr("Zoek in het logboek", "Search the log")} />
  </div>
  {#each audit.slice(0, 100) as entry (entry.id)}
    <div class="row entry-row">
      <span class="entry-head"><strong>{entry.tool}</strong><span class="when">{new Date(entry.date).toLocaleString(locale(), { dateStyle: "medium", timeStyle: "short" })}</span></span>
      {#if entry.result}<span class="result" class:failed={entry.result.startsWith("FOUT")}>{entry.result}</span>{/if}
      {#if entry.args && entry.args !== "{}"}<code class="args">{entry.args}</code>{/if}
    </div>
  {:else}
    <p class="empty-note">{tr("Nog niets uitgevoerd.", "Nothing carried out yet.")}</p>
  {/each}
  <div class="row log-foot">
    {#if cleared}<small>{tr("Logboek gewist.", "Log cleared.")}</small>{/if}
    <ConfirmedButton class="small" question={tr("Het auditlog wissen?", "Clear the audit log?")} detail={tr("Elke vastgelegde actie wordt verwijderd.", "Every logged action is deleted.")}
      confirmTitle={tr("Logboek wissen", "Clear log")} disabled={audit.length === 0}
      onconfirm={async () => { await api.clearAudit(); audit = []; cleared = true; }} />
  </div>
</div>
{/if}

<style>
  .note.ok { display: inline-flex; align-items: center; gap: var(--space-4); color: var(--mint); }
  .promise { flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-12); }
  .promise-icon { display: grid; place-items: center; width: 18px; color: var(--text2); }
  .promise-title { flex: 0 1 auto; }
  .promise-info { display: inline-grid; place-items: center; color: var(--text3); }
  .linked { flex-wrap: nowrap; }
  .plain { display: flex; align-items: center; gap: var(--space-12); }
  .text { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .log-search { flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-6); color: var(--text3); }
  .log-search input { flex: 1; min-width: 0; padding: 0; border: none; background: none; box-shadow: none; outline: none; color: var(--paper); font: var(--text-body); }
  .entry-row { flex-direction: column; align-items: stretch; gap: var(--space-2); }
  .entry-head { display: flex; justify-content: space-between; gap: var(--space-12); }
  .entry-head strong { font: var(--text-emphasis); color: var(--paper); }
  .when, .result { font: var(--text-detail); color: var(--text2); }
  .result { display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .result.failed { color: var(--coral); }
  .args { font: var(--text-code); color: var(--text3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; user-select: text; }
  .log-foot { justify-content: flex-end; }
</style>
