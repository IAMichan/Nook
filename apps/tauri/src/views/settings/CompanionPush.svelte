<script lang="ts">
  // Pushmeldingen naar de iPhone (zoals Instellingen › iPhone-metgezel › Pushmeldingen op de Mac): welke, wanneer, en
  // de eigen Apple-sleutel waarmee deze computer ze zelf naar Apple stuurt.
  import { companion, type CompanionInfo, type PushKind, type PushSettings } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";

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

  const kinds: [PushKind, string][] = $derived([
    ["approval", tr("Toestemming nodig", "Permission needed")],
    ["question", tr("Vraag van de agent", "Question from the agent")],
    ["finished", tr("Sessie klaar", "Session done")],
    ["failed", tr("Sessie mislukt", "Session failed")],
    ["limited", tr("Limiet bereikt", "Limit reached")],
  ]);
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
  <label class="row"><span>{tr("Pushmeldingen", "Push notifications")}</span><input type="checkbox" checked={s.enabled} onchange={(e) => save({ enabled: e.currentTarget.checked })} /></label>
  <p class="faint note">
    {tr(
      "Alleen voor Nook Companion op de iPhone. Nook stuurt de melding zelf naar Apple met je eigen sleutel; er zit geen server van ons tussen. Apple ziet de tekst, daarom noemt die alleen de agent en wat er nodig is, nooit een commando of antwoord. Nook op Android heeft geen pushmeldingen nodig: die meldt zelf wat er nieuw is zolang de app in het geheugen staat.",
      "Only for Nook Companion on iPhone. Nook sends the notification to Apple itself with your own key; there's no server of ours in between. Apple sees the text, so it only names the agent and what's needed, never a command or answer. Nook on Android doesn't need push notifications: it reports what's new itself as long as the app is in memory.",
    )}
  </p>
  {#if s.enabled}
    {#each kinds as [kind, label] (kind)}
      <label class="row sub"><span>{label}</span><input type="checkbox" checked={s.kinds.includes(kind)} onchange={(e) => toggleKind(kind, e.currentTarget.checked)} /></label>
    {/each}
    <label class="row"><span>{tr("Alleen als ik niet bij de computer ben", "Only when I'm away from the computer")}</span><input type="checkbox" checked={s.onlyWhenAway} onchange={(e) => save({ onlyWhenAway: e.currentTarget.checked })} /></label>
    <label class="row"><span>{tr("Noem de titel van de sessie", "Include the session title")}</span><input type="checkbox" checked={s.includeTitle} onchange={(e) => save({ includeTitle: e.currentTarget.checked })} /></label>
    <label class="row">
      <span>{tr("Stille uren", "Quiet hours")}</span>
      <input type="checkbox" checked={s.quietFrom != null} onchange={(e) => save(e.currentTarget.checked ? { quietFrom: 22, quietTo: 7 } : { quietFrom: null, quietTo: null })} />
    </label>
    {#if s.quietFrom != null}
      <div class="row sub">
        <span class="inline">
          {tr("Van", "From")}
          <select value={s.quietFrom} onchange={(e) => save({ quietFrom: Number(e.currentTarget.value) })}>
            {#each hours as h (h)}<option value={h}>{h}:00</option>{/each}
          </select>
          {tr("tot", "to")}
          <select value={s.quietTo ?? 7} onchange={(e) => save({ quietTo: Number(e.currentTarget.value) })}>
            {#each hours as h (h)}<option value={h}>{h}:00</option>{/each}
          </select>
        </span>
      </div>
      <label class="row sub"><span>{tr("Toestemming en vragen komen toch door", "Permissions and questions still come through")}</span><input type="checkbox" checked={s.quietAllowsUrgent} onchange={(e) => save({ quietAllowsUrgent: e.currentTarget.checked })} /></label>
    {/if}
  {/if}
</div>

{#if s.enabled}
  <h3>{tr("Apple-sleutel voor meldingen", "Apple key for notifications")}</h3>
  <div class="group">
    <p class="faint note">
      {tr(
        "Maak in je Apple Developer-account een APNs-sleutel (Certificates, Identifiers & Profiles › Keys) en zet Push Notifications aan voor de app-id nl.imdigital.nook.companion. Vul het sleutel-id en team-id in en importeer het .p8-bestand; dat gaat naar de kluis van je computer.",
        "In your Apple Developer account, create an APNs key (Certificates, Identifiers & Profiles › Keys) and turn on Push Notifications for the app ID nl.imdigital.nook.companion. Fill in the key ID and team ID and import the .p8 file; it goes to your computer's keychain.",
      )}
    </p>
    <div class="row">
      <span class="inline">
        <input placeholder={tr("Sleutel-id (10 tekens)", "Key ID (10 characters)")} bind:value={keyId} maxlength="10" onchange={() => saveIds()} />
        <input placeholder={tr("Team-id (10 tekens)", "Team ID (10 characters)")} bind:value={teamId} maxlength="10" onchange={() => saveIds()} />
      </span>
    </div>
    <div class="row">
      <span class="inline">
        {#if push.hasKey}
          <span class="muted">✓ {tr("Sleutel bewaard", "Key saved")}</span>
          <button onclick={async () => onchange(await companion.removeApnsKey())}>{tr("Verwijder", "Remove")}</button>
        {:else}
          <label class="file">
            {tr("Importeer .p8-sleutel", "Import .p8 key")}
            <input type="file" accept=".p8,application/x-pem-file,text/plain" onchange={importKey} />
          </label>
        {/if}
        <button disabled={!push.canPush || !info.devices.some((d) => d.push) || testing} onclick={test}>{tr("Stuur testmelding", "Send a test notification")}</button>
      </span>
    </div>
    {#if keyProblem}<p class="err">{keyProblem}</p>{/if}
    {#if !push.canPush}<p class="faint note">{tr("Vul sleutel-id en team-id in en importeer de sleutel om meldingen te kunnen sturen.", "Fill in the key ID and team ID and import the key to be able to send notifications.")}</p>{/if}
    {#if testResult ?? push.lastResult}<p class="faint note">{testResult ?? push.lastResult}</p>{/if}
  </div>
{/if}

<style>
  .sub { padding-left: 14px; }
  .file { position: relative; overflow: hidden; display: inline-block; background: var(--smoke); border: 1px solid var(--line2); border-radius: 9px; padding: 6px 12px; cursor: pointer; }
  .file input { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
  .inline input { width: 170px; }
</style>
