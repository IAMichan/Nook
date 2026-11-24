<script lang="ts">
  // A database Nook could not open, or set aside because it was damaged (the Mac's storage incidents in the panel):
  // which file, why, where the copy is, and what to do; it stays until you dismiss it.
  import { invoke } from "@tauri-apps/api/core";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../ui/Ico.svelte";
  import { toast } from "../../lib/toast.svelte";

  interface Incident { id: number; file: string; kind: "damaged" | "unavailable"; reason: string; movedTo: string | null; recoverCommand: string | null }
  let incidents = $state<Incident[]>([]);
  const load = () => invoke<Incident[]>("storage_incidents").then((i) => (incidents = i)).catch(() => {});
  $effect(() => { load(); });
  const name = (path: string) => path.split(/[\\/]/).pop() ?? path;
  const database = (path: string) => path.endsWith(".sqlite");
  // The command that reads what is still readable from the copy into a new file beside it (the Mac's `copyRecoveryCommand`).
  async function copyCommand(command: string) {
    try {
      await navigator.clipboard.writeText(command);
      toast.success(tr("Herstelopdracht gekopieerd", "Recovery command copied"));
    } catch (e) {
      toast.error(tr("Kopiëren lukte niet", "Could not copy"), e);
    }
  }
  async function dismiss(id: number) { await invoke("storage_incident_dismiss", { id }).catch(() => {}); load(); }
</script>

{#each incidents as i (i.id)}
  <div class="storage" role="alert">
    <span class="mark"><Ico name="triangle-alert" size={15} /></span>
    <div class="text">
      {#if i.kind === "damaged"}
        <strong>{tr("{file} was beschadigd en is apart gezet", "{file} was damaged and has been set aside", { file: name(i.file) })}</strong>
        {#if database(i.file)}
          <span>{tr("SQLite kon het niet lezen ({reason}). Nook heeft het verplaatst naar {copy} en is met een leeg bestand begonnen, zodat alles blijft werken. Er is niets verwijderd.", "SQLite could not read it ({reason}). Nook moved it to {copy} and started with an empty one, so it keeps working. Nothing was deleted.", { reason: i.reason, copy: name(i.movedTo ?? "") })}</span>
        {:else}
          <span>{tr("Nook kon het niet lezen ({reason}). Het is verplaatst naar {copy} en Nook is leeg begonnen, zodat alles blijft werken. Er is niets verwijderd.", "Nook could not read it ({reason}). It was moved to {copy} and Nook started empty, so it keeps working. Nothing was deleted.", { reason: i.reason, copy: name(i.movedTo ?? "") })}</span>
        {/if}
        {#if i.recoverCommand}
          <span>{tr("Om het terug te halen: stop Nook, voer de herstelopdracht uit in een terminal en zet het herstelde bestand op {file}.", "To get it back, quit Nook and run the recovery command in a terminal, then move the recovered file to {file}.", { file: i.file })}</span>
        {/if}
      {:else}
        <strong>{tr("Nook kon {file} niet openen", "Nook could not open {file}", { file: name(i.file) })}</strong>
        <span>{tr("SQLite zei: {reason}. Het bestand blijft waar het is en wordt pas weer bewaard als Nook het kan openen. Kijk of de schijf ruimte heeft en de map schrijfbaar is, en start Nook dan opnieuw.", "SQLite said: {reason}. The file is left where it is and nothing is saved to it until Nook can open it again. Check that the disk has space and the folder is writable, then restart Nook.", { reason: i.reason })}</span>
      {/if}
    </div>
    <div class="actions">
      <button class="ghost" onclick={() => invoke("storage_reveal", { id: i.id }).catch(() => {})}>{tr("Toon in map", "Show in folder")}</button>
      {#if i.recoverCommand}<button class="ghost" onclick={() => copyCommand(i.recoverCommand!)}>{tr("Kopieer herstelopdracht", "Copy recovery command")}</button>{/if}
      <button class="ghost" onclick={() => dismiss(i.id)}>{tr("Sluit", "Close")}</button>
    </div>
  </div>
{/each}

<style>
  .storage { position: fixed; top: calc(52px + var(--space-8)); left: 50%; transform: translateX(-50%); z-index: 46; display: flex; align-items: flex-start; gap: var(--space-8); width: min(560px, calc(100vw - 32px)); padding: var(--space-12); background: var(--menu); border: 1px solid color-mix(in srgb, var(--coral) 40%, var(--line2)); border-radius: var(--radius-card); box-shadow: var(--shadow-popover); }
  .mark { color: var(--coral); display: inline-flex; padding-top: 2px; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-4); }
  strong { font: var(--text-emphasis); color: var(--paper); }
  span { font: var(--text-detail); color: var(--text2); }
  .actions { display: flex; flex-direction: column; gap: var(--space-4); }
  .actions button { padding: var(--space-4) var(--space-8); border: 0; border-radius: var(--radius-control); font: var(--text-control); color: var(--text2); white-space: nowrap; }
  .actions button:hover { background: var(--row-hover); color: var(--paper); }
</style>
