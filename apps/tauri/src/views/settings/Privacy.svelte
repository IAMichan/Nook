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
  import StatusRow from "./StatusRow.svelte";
  import { tip } from "../../components/ui/tip";

  // Windows' privacy switches for what Nook uses (none on other systems), read again when the window comes back.
  let permissions = $state<{ id: string; granted: boolean }[]>([]);
  $effect(() => {
    const read = () => invoke<{ id: string; granted: boolean }[]>("permissions_overview").then((p) => (permissions = Array.isArray(p) ? p : [])).catch(() => {});
    read();
    window.addEventListener("focus", read);
    return () => window.removeEventListener("focus", read);
  });
  const permissionTitle = (id: string) => (id === "microphone" ? tr("Microfoon", "Microphone") : tr("Meldingen", "Notifications"));
  const permissionDetail = (id: string) => (id === "microphone"
    ? tr("Om met Nook te praten, te dicteren en gesprekken te noteren.", "To talk to Nook, dictate and take call notes.")
    : tr("Voor meldingen van Windows als je die kiest bij Meldingen.", "For Windows notifications when you choose them under Notifications."));

  let audit = $state<AuditEntry[]>([]);
  let auditQuery = $state("");
  let overview = $state<Overview | null>(null);
  let cleared = $state(false);

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

{#if nook.info?.capabilities.screenReading}
  <div class="group">
    <div class="row">
      <span>{tr("Schermtekst", "Screen text")}</span>
      <ConfirmedButton class="small" question={tr("Vergeten wat Nook net zag?", "Forget what Nook just saw?")} confirmTitle={tr("Vergeet wat Nook nu zag", "Forget what Nook just saw")}
        onconfirm={async () => { await services.screenForget(); toast.success(tr("Schermtekst vergeten.", "Screen text forgotten.")); }} />
    </div>
  </div>
{/if}

{#if permissions.length}
  <!-- The Mac's Permissions (`SystemPermission`): what Windows lets Nook use, with a check once it may, and the page in
       Windows Settings that changes it. -->
  <h3>{tr("Machtigingen", "Permissions")}</h3>
  <div class="group">
    {#each permissions as p (p.id)}
      <StatusRow done={p.granted} title={permissionTitle(p.id)} detail={p.granted ? "" : permissionDetail(p.id)}>
        <button use:tip={p.granted ? tr("Alleen jij kunt dit uitzetten, in de Windows-instellingen › Privacy en beveiliging. Dit opent die pagina.", "Only you can turn this off, in Windows Settings › Privacy & security. This opens that page.") : undefined}
          class="small" onclick={() => invoke("permissions_open", { id: p.id }).catch(() => {})}>{p.granted ? tr("Intrekken…", "Revoke…") : tr("Toestaan", "Allow")}</button>
      </StatusRow>
    {/each}
  </div>
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

<style>
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
