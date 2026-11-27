<script lang="ts">
  // The password of a machine that logs in with one (`RemotePasswordField` on the Mac): typed once per run of Nook, or
  // kept in the system's secret store when you choose that. Nook logs in with it first; a password that does not get in
  // is not kept. Used in Settings › Devices › Machines and under the composer.
  import { tr } from "../../lib/i18n.svelte";
  import { machinesApi, type RemoteMachine } from "../../lib/workspace/machines";

  let { machine, onunlocked }: { machine: RemoteMachine; onunlocked?: () => void } = $props();
  let password = $state("");
  let keep = $state(false);
  let busy = $state(false);
  let error = $state<string | null>(null);

  async function unlock() {
    if (busy || !password) return;
    busy = true;
    error = null;
    try {
      await machinesApi.unlock(machine.id, password, keep);
      password = "";
      onunlocked?.();
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }
</script>

<form class="pw" onsubmit={(e) => { e.preventDefault(); unlock(); }}>
  <input type="password" bind:value={password} autocomplete="off" placeholder={tr("Wachtwoord voor {machine}", "Password for {machine}", { machine: machine.name })}
    aria-label={tr("Wachtwoord voor {machine}", "Password for {machine}", { machine: machine.name })} />
  <label class="keep"><input type="checkbox" bind:checked={keep} /> {tr("Bewaar in de sleutelkluis", "Keep in the secret store")}</label>
  <button type="submit" class="primary" disabled={busy || !password}>{busy ? tr("Verbinden…", "Connecting…") : tr("Ontgrendel", "Unlock")}</button>
  {#if error}<p class="err">{error}</p>{/if}
</form>

<style>
  .pw { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-8); width: 100%; }
  .pw input[type="password"] { flex: 1 1 180px; min-width: 0; }
  .keep { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-detail); color: var(--text2); white-space: nowrap; }
  .err { flex-basis: 100%; margin: 0; font: var(--text-detail); color: var(--coral); }
</style>
