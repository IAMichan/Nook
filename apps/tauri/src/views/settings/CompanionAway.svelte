<script lang="ts">
  // Always reachable: the phone reaches this computer away from home (the relay, or Tailscale), the computer stays
  // awake for it, and Nook keeps running (Task Scheduler on Windows, a systemd user service on Linux). As on the Mac
  // (Settings › iPhone › Away from home); the background task follows how t3code runs its server as a service.
  import { companion, type CompanionInfo, type KeepAwakeMode } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";

  let { info, onchange }: { info: CompanionInfo; onchange: (info: CompanionInfo) => void } = $props();

  const away = $derived(info.away!);
  let address = $state("");
  let error = $state<string | null>(null);
  let testing = $state(false);
  let testResult = $state<string | null>(null);
  $effect(() => {
    address = away.relay.address;
  });
  // Your own relay is the only choice in a build without Nook's.
  const own = $derived(away.relay.own || !away.nookRelay);

  async function run(f: () => Promise<CompanionInfo>) {
    error = null;
    try {
      onchange(await f());
    } catch (e) {
      error = String(e);
    }
  }

  const setRelay = (enabled: boolean, useOwn: boolean) => run(() => companion.setRelay(enabled, useOwn, address));

  async function test() {
    testing = true;
    testResult = null;
    try {
      const ms = await companion.testRelay();
      testResult = tr("Werkt: heen en terug in {ms} ms.", "Works: round trip in {ms} ms.", { ms });
    } catch (e) {
      testResult = String(e);
    } finally {
      testing = false;
    }
  }

  const reasonText = $derived.by(() => {
    switch (away.keepAwakeDecision?.reason) {
      case "working":
        return tr("Nu wakker gehouden: er werken agents of er wacht iets op je.", "Kept awake now: agents are working or something waits on you.");
      case "phone":
        return tr("Nu wakker gehouden: je telefoon is verbonden.", "Kept awake now: your phone is connected.");
      case "always":
        return tr("Nu wakker gehouden: altijd, op netstroom.", "Kept awake now: always, on power.");
      default:
        return null;
    }
  });
</script>

<h3>{tr("Altijd bereikbaar", "Always reachable")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Bereik deze computer buiten de deur", "Reach this computer away from home")}</span>
    <input type="checkbox" checked={away.relay.enabled} onchange={(e) => setRelay(e.currentTarget.checked, own)} />
  </label>
  {#if away.relay.enabled}
    {#if away.nookRelay}
      <label class="row sub">
        <span>{tr("Relay", "Relay")}</span>
        <select value={own ? "own" : "nook"} onchange={(e) => setRelay(true, e.currentTarget.value === "own")}>
          <option value="nook">{tr("Die van Nook", "Nook's")}</option>
          <option value="own">{tr("Mijn eigen relay", "My own relay")}</option>
        </select>
      </label>
    {/if}
    {#if own}
      <div class="row sub">
        <input class="address" placeholder="https://nook-relay.you.workers.dev" bind:value={address} onchange={() => setRelay(true, true)} />
      </div>
    {/if}
    <div class="row sub status">
      {#if away.relayStatus.state === "connected"}
        <span class="ok">{tr("Verbonden met de relay. Je telefoon vindt deze computer nu ook onderweg.", "Connected to the relay. Your phone now finds this computer on the go too.")}</span>
      {:else if away.relayStatus.state === "connecting"}
        <span class="faint">{tr("Verbinden met de relay…", "Connecting to the relay…")}</span>
      {:else if away.relayStatus.state === "failed"}
        <span class="err">{tr("De relay is niet bereikbaar: {message}", "The relay can't be reached: {message}", { message: away.relayStatus.message })}</span>
      {:else if away.relayStatus.state === "invalid"}
        <span class="faint">{tr("Vul het https-adres van je relay in.", "Fill in your relay's https address.")}</span>
      {:else}
        <span class="faint">{tr("Gaat aan zodra er een telefoon gekoppeld is.", "Turns on once a phone is paired.")}</span>
      {/if}
      {#if away.relayStatus.state === "connected" && info.devices.length > 0}
        <button disabled={testing} onclick={test}>{testing ? tr("Testen…", "Testing…") : tr("Test relay", "Test relay")}</button>
      {/if}
    </div>
    {#if testResult}<p class="faint note">{testResult}</p>{/if}
  {/if}
  <p class="faint note">
    {tr(
      "Zonder Tailscale en zonder poort open te zetten in je router: deze computer belt zelf naar de relay en je telefoon ontmoet hem daar. Alles blijft versleuteld met de koppelsleutel; de relay ziet alleen wanneer en hoeveel er gaat. Je eigen relay zet je op met apps/relay op je eigen Cloudflare-account.",
      "No Tailscale and no port opened on your router: this computer calls out to the relay and your phone meets it there. Everything stays encrypted with the pairing key; the relay only sees when and how much goes through. Set up your own relay with apps/relay on your own Cloudflare account.",
    )}
    {#if away.tailscale}
      {tr("Je telefoon kent ook het Tailscale-adres van deze computer.", "Your phone also knows this computer's Tailscale address.")}
    {/if}
  </p>

  <label class="row">
    <span>{tr("Houd deze computer wakker", "Keep this computer awake")}</span>
    <select value={away.keepAwake} onchange={(e) => run(() => companion.setKeepAwake(e.currentTarget.value as KeepAwakeMode))}>
      <option value="off">{tr("Nooit", "Never")}</option>
      <option value="whileWorking">{tr("Terwijl agents werken of je telefoon verbonden is", "While agents work or your phone is connected")}</option>
      <option value="always">{tr("Altijd (op netstroom)", "Always (on power)")}</option>
    </select>
  </label>
  <p class="faint note">
    {reasonText ?? ""}
    {tr(
      "Een computer die slaapt is net zo onbereikbaar als een die uit staat. Het scherm mag nog steeds uit; op de accu nooit onder 20%. Een dichtgeklapte laptop volgt de instelling van je energiebeheer.",
      "A computer that sleeps is as unreachable as one that is off. The screen may still turn off; on battery never below 20%. A closed laptop lid follows your power settings.",
    )}
  </p>

  {#if away.backgroundSupported}
    <label class="row">
      <span>{tr("Houd Nook draaiend", "Keep Nook running")}</span>
      <input type="checkbox" checked={away.background} onchange={(e) => run(() => companion.setBackground(e.currentTarget.checked))} />
    </label>
    <p class="faint note">
      {tr(
        "Start Nook zonder venster als je inlogt, en opnieuw als het stopt. Wil je Nook helemaal afsluiten, zet dit dan eerst uit. Vergrendel je scherm in plaats van af te melden: Nook draait in jouw sessie.",
        "Starts Nook without a window when you sign in, and again if it stops. To quit Nook for good, turn this off first. Lock your screen instead of signing out: Nook runs in your session.",
      )}
    </p>
  {/if}
</div>
{#if error}<p class="err">{error}</p>{/if}

<style>
  .status { justify-content: space-between; gap: 12px; }
  .address { flex: 1; min-width: 0; }
  .ok { color: var(--mint); }
  .sub { padding-left: 14px; }
</style>
