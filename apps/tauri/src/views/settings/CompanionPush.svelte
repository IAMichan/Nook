<script lang="ts">
  // Pushmeldingen naar de iPhone (zoals Instellingen › iPhone-metgezel › Pushmeldingen op de Mac): welke, wanneer, en
  // de eigen Apple-sleutel waarmee deze computer ze zelf naar Apple stuurt.
  import { companion, type CompanionInfo, type PushKind, type PushSettings } from "../../lib/companion";

  let { info, onchange }: { info: CompanionInfo; onchange: (i: CompanionInfo) => void } = $props();
  const push = $derived(info.push!);
  const s = $derived(push.settings);
  let keyId = $state("");
  let teamId = $state("");
  let keyProblem = $state<string | null>(null);
  let testResult = $state<string | null>(null);
  let testing = $state(false);

  $effect(() => {
    keyId = push.keyId;
    teamId = push.teamId;
  });

  const kinds: [PushKind, string][] = [
    ["approval", "Toestemming nodig"],
    ["question", "Vraag van de agent"],
    ["finished", "Sessie klaar"],
    ["failed", "Sessie mislukt"],
    ["limited", "Limiet bereikt"],
  ];
  const hours = Array.from({ length: 24 }, (_, h) => h);

  async function save(patch: Partial<PushSettings>) {
    onchange(await companion.setPush({ ...s, ...patch }));
  }

  function toggleKind(kind: PushKind, on: boolean) {
    save({ kinds: on ? [...new Set([...s.kinds, kind])] : s.kinds.filter((k) => k !== kind) });
  }

  async function saveIds(pem?: string) {
    keyProblem = null;
    try {
      onchange(await companion.setApns(keyId, teamId, pem));
    } catch (e) {
      keyProblem = String(e);
    }
  }

  // Het .p8-bestand wordt alleen gelezen om het in de kluis te zetten; de inhoud komt niet terug in de interface.
  function importKey(e: Event) {
    const file = (e.currentTarget as HTMLInputElement).files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => saveIds(String(reader.result));
    reader.readAsText(file);
    (e.currentTarget as HTMLInputElement).value = "";
  }

  async function test() {
    testing = true;
    try {
      testResult = await companion.pushTest();
    } catch (e) {
      testResult = String(e);
    }
    testing = false;
  }
</script>

<div class="group">
  <label class="row"><span>Pushmeldingen</span><input type="checkbox" checked={s.enabled} onchange={(e) => save({ enabled: e.currentTarget.checked })} /></label>
  <p class="faint note">
    Alleen voor Nook Companion op de iPhone. Nook stuurt de melding zelf naar Apple met je eigen sleutel; er zit geen server
    van ons tussen. Apple ziet de tekst, daarom noemt die alleen de agent en wat er nodig is, nooit een commando of antwoord.
    Nook op Android heeft geen pushmeldingen nodig: die meldt zelf wat er nieuw is zolang de app in het geheugen staat.
  </p>
  {#if s.enabled}
    {#each kinds as [kind, label] (kind)}
      <label class="row sub"><span>{label}</span><input type="checkbox" checked={s.kinds.includes(kind)} onchange={(e) => toggleKind(kind, e.currentTarget.checked)} /></label>
    {/each}
    <label class="row"><span>Alleen als ik niet bij de computer ben</span><input type="checkbox" checked={s.onlyWhenAway} onchange={(e) => save({ onlyWhenAway: e.currentTarget.checked })} /></label>
    <label class="row"><span>Noem de titel van de sessie</span><input type="checkbox" checked={s.includeTitle} onchange={(e) => save({ includeTitle: e.currentTarget.checked })} /></label>
    <label class="row">
      <span>Stille uren</span>
      <input type="checkbox" checked={s.quietFrom != null} onchange={(e) => save(e.currentTarget.checked ? { quietFrom: 22, quietTo: 7 } : { quietFrom: null, quietTo: null })} />
    </label>
    {#if s.quietFrom != null}
      <div class="row sub">
        <span class="inline">
          Van
          <select value={s.quietFrom} onchange={(e) => save({ quietFrom: Number(e.currentTarget.value) })}>
            {#each hours as h (h)}<option value={h}>{h}:00</option>{/each}
          </select>
          tot
          <select value={s.quietTo ?? 7} onchange={(e) => save({ quietTo: Number(e.currentTarget.value) })}>
            {#each hours as h (h)}<option value={h}>{h}:00</option>{/each}
          </select>
        </span>
      </div>
      <label class="row sub"><span>Toestemming en vragen komen toch door</span><input type="checkbox" checked={s.quietAllowsUrgent} onchange={(e) => save({ quietAllowsUrgent: e.currentTarget.checked })} /></label>
    {/if}
  {/if}
</div>

{#if s.enabled}
  <h3>Apple-sleutel voor meldingen</h3>
  <div class="group">
    <p class="faint note">
      Maak in je Apple Developer-account een APNs-sleutel (Certificates, Identifiers &amp; Profiles › Keys) en zet Push
      Notifications aan voor de app-id nl.imdigital.nook.companion. Vul het sleutel-id en team-id in en importeer het
      .p8-bestand; dat gaat naar de kluis van je computer.
    </p>
    <div class="row">
      <span class="inline">
        <input placeholder="Sleutel-id (10 tekens)" bind:value={keyId} maxlength="10" onchange={() => saveIds()} />
        <input placeholder="Team-id (10 tekens)" bind:value={teamId} maxlength="10" onchange={() => saveIds()} />
      </span>
    </div>
    <div class="row">
      <span class="inline">
        {#if push.hasKey}
          <span class="muted">✓ Sleutel bewaard</span>
          <button onclick={async () => onchange(await companion.removeApnsKey())}>Verwijder</button>
        {:else}
          <label class="file">
            Importeer .p8-sleutel
            <input type="file" accept=".p8,application/x-pem-file,text/plain" onchange={importKey} />
          </label>
        {/if}
        <button disabled={!push.canPush || !info.devices.some((d) => d.push) || testing} onclick={test}>Stuur testmelding</button>
      </span>
    </div>
    {#if keyProblem}<p class="err">{keyProblem}</p>{/if}
    {#if !push.canPush}<p class="faint note">Vul sleutel-id en team-id in en importeer de sleutel om meldingen te kunnen sturen.</p>{/if}
    {#if testResult ?? push.lastResult}<p class="faint note">{testResult ?? push.lastResult}</p>{/if}
  </div>
{/if}

<style>
  .sub { padding-left: 14px; }
  .file { position: relative; overflow: hidden; display: inline-block; background: var(--smoke); border: 1px solid var(--line2); border-radius: 9px; padding: 6px 12px; cursor: pointer; }
  .file input { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
  .inline input { width: 170px; }
</style>
