<script lang="ts">
  // Privacy & security: everything Nook is signed in to (as Settings › Privacy › Access on the Mac), and the activity
  // log. Managing happens on Accounts & connections; this list only says what Nook can reach.
  import { api } from "../../lib/api";
  import type { AuditEntry } from "../../lib/types";
  import { connectorsApi, connectorEvents, type Overview } from "../../lib/connectors";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";

  let audit = $state<AuditEntry[]>([]);
  let auditQuery = $state("");
  let overview = $state<Overview | null>(null);

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

<h2>{tr("Privacy & beveiliging", "Privacy & security")}</h2>
<h3>{tr("Gekoppelde accounts en diensten", "Linked accounts and services")}</h3>
<p class="muted">{tr("Alles waar Nook bij is ingelogd. Met Beheer open je de koppeling om hem uit te zetten of te verwijderen; verwijderen wist ook de sleutel of het token uit je sleutelhanger.", "Everything Nook is signed in to. Manage opens the link, where you can switch it off or remove it; removing also deletes its key or token from your keychain.")}</p>
{#each linked as item (item.id)}
  <div class="row">
    <span class="plain">
      <ServiceIcon domain={item.domain} title={item.title} />
      <span class="text">
        <span>{item.title}</span>
        <span class="faint small">{item.detail}</span>
      </span>
    </span>
    <button class="ghost" onclick={manage}>{tr("Beheer", "Manage")}</button>
  </div>
{:else}
  <p class="faint">{tr("Nog niets gekoppeld.", "Nothing linked yet.")}</p>
{/each}

<h3>{tr("Activiteitenlog", "Activity log")}</h3>
<p class="muted">{tr("Alles wat Nook namens jou deed, staat hier 90 dagen. Alleen op deze computer.", "Everything Nook did on your behalf stays here for 90 days. Only on this computer.")}</p>
<div class="inline">
  <input placeholder={tr("Zoek in het logboek", "Search the log")} bind:value={auditQuery} />
  <button class="danger" onclick={async () => { await api.clearAudit(); audit = []; }}>{tr("Leegmaken", "Clear")}</button>
</div>
<div class="audit">
  {#each audit as entry (entry.id)}
    <div class="entry">
      <span class="faint">{new Date(entry.date).toLocaleString(locale())}</span>
      <strong>{entry.tool}</strong>
      <span class="muted">{entry.result}</span>
    </div>
  {:else}
    <p class="faint">{tr("Nog niets gedaan.", "Nothing done yet.")}</p>
  {/each}
</div>
      
