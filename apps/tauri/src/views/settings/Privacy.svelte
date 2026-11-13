<script lang="ts">
  // Privacy & beveiliging: het actielogboek.
  import { api } from "../../lib/api";
  import type { AuditEntry } from "../../lib/types";
  import { tr, locale } from "../../lib/i18n.svelte";

  let audit = $state<AuditEntry[]>([]);
  let auditQuery = $state("");

  $effect(() => {
    api.auditEntries(auditQuery).then((a) => (audit = a));
  });
</script>

<h2>{tr("Privacy & beveiliging", "Privacy & security")}</h2>
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
      
