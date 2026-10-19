<script lang="ts">
  // Privacy & beveiliging: het actielogboek.
  import { api } from "../../lib/api";
  import type { AuditEntry } from "../../lib/types";

  let audit = $state<AuditEntry[]>([]);
  let auditQuery = $state("");

  $effect(() => {
    api.auditEntries(auditQuery).then((a) => (audit = a));
  });
</script>

<h2>Privacy & beveiliging</h2>
<p class="muted">Alles wat Nook namens jou deed, staat hier 90 dagen. Alleen op deze computer.</p>
<div class="inline">
  <input placeholder="Zoek in het logboek" bind:value={auditQuery} />
  <button class="danger" onclick={async () => { await api.clearAudit(); audit = []; }}>Leegmaken</button>
</div>
<div class="audit">
  {#each audit as entry (entry.id)}
    <div class="entry">
      <span class="faint">{new Date(entry.date).toLocaleString("nl-NL")}</span>
      <strong>{entry.tool}</strong>
      <span class="muted">{entry.result}</span>
    </div>
  {:else}
    <p class="faint">Nog niets gedaan.</p>
  {/each}
</div>
      
