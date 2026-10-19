<script lang="ts">
  // Companion: een telefoon (de iPhone-app, of Nook op Android) koppelen met deze computer, zoals op de Mac
  // (Instellingen › iPhone-metgezel). Aanzetten, een code tonen die vijf minuten en één keer werkt, toestellen weghalen.
  import { companion, type CompanionInfo } from "../../lib/companion";
  import { relativeTime } from "../../lib/state.svelte";

  let info = $state<CompanionInfo | null>(null);
  let error = $state<string | null>(null);
  let copied = $state(false);
  let host = $state<string | undefined>(undefined);

  async function run(f: () => Promise<CompanionInfo>) {
    error = null;
    try {
      info = await f();
    } catch (e) {
      error = String(e);
    }
  }

  $effect(() => {
    run(companion.info);
  });

  // Terwijl de code openstaat: kijken of de telefoon hem gebruikte (dan verdwijnt hij) of dat hij verliep.
  $effect(() => {
    if (!info?.pairing) return;
    const t = setInterval(() => run(companion.info), 2000);
    return () => clearInterval(t);
  });

  const listening = $derived(info?.state?.state === "listening");
  const minutesLeft = $derived(info?.pairing ? Math.max(0, Math.ceil((new Date(info.pairing.until).getTime() - Date.now()) / 60000)) : 0);

  async function copy() {
    if (!info?.pairing) return;
    try {
      await navigator.clipboard.writeText(info.pairing.url);
      copied = true;
    } catch {
      error = "Kopiëren lukte niet; selecteer de link en kopieer hem zelf.";
    }
  }
</script>

<h2>Companion</h2>
<p class="muted">
  Laat een gekoppelde telefoon in je eigen wifi zien welke sessies je nodig hebben, en laat je goedkeuren, antwoorden, een
  bericht sturen of stoppen. Werkt met Nook Companion op de iPhone en met Nook op Android. Alles gaat versleuteld;
  riskante goedkeuringen (zoals onbekende commando’s) kun je vanaf de telefoon alleen weigeren.
</p>

{#if info}
  <div class="group">
    <label class="row">
      <span>Companion op je telefoon</span>
      <input type="checkbox" checked={info.enabled} onchange={(e) => run(() => companion.setEnabled(e.currentTarget.checked))} />
    </label>
    {#if info.enabled}
      <div class="row status">
        {#if info.state?.state === "listening"}
          <span class="muted">Luistert op poort {info.state.port} in je lokale netwerk als <strong>{info.computerName}</strong>.</span>
        {:else if info.state?.state === "failed"}
          <span class="err">Kan niet starten: {info.state.message}</span>
        {:else}
          <span class="faint">Start…</span>
        {/if}
      </div>
    {/if}
  </div>

  {#if info.enabled}
    <h3>Gekoppelde telefoons</h3>
    <div class="group">
      {#each info.devices as device (device.id)}
        <div class="row">
          <div class="device">
            <span>📱 {device.name}</span>
            <span class="faint small">{device.lastSeen ? `Laatst gezien: ${relativeTime(device.lastSeen)}` : "Nog niet verbonden"}</span>
          </div>
          <button onclick={() => run(() => companion.removeDevice(device.id))}>Ontkoppel</button>
        </div>
      {:else}
        <p class="faint note">Nog geen telefoon gekoppeld.</p>
      {/each}
    </div>

    {#if info.pairing}
      <div class="pairing">
        <div class="qr" role="img" aria-label="QR-code om te koppelen">{@html info.pairing.qrSvg}</div>
        <div class="steps">
          <p>Open Nook Companion op je iPhone, of Nook op Android › Companion, en scan deze code of plak de link. De code werkt nog {minutesLeft} {minutesLeft === 1 ? "minuut" : "minuten"} en één keer.</p>
          <code class="link">{info.pairing.url}</code>
          <div class="inline">
            <button onclick={copy}>{copied ? "Gekopieerd" : "Kopieer link"}</button>
            <button class="ghost" onclick={() => { copied = false; run(companion.cancelPairing); }}>Stop koppelen</button>
          </div>
        </div>
      </div>
    {:else}
      <div class="inline pairrow">
        <button class="primary" disabled={!listening} onclick={() => { copied = false; run(() => companion.beginPairing(host)); }}>Koppel een telefoon</button>
        {#if info.hosts.length > 1}
          <label class="inline faint">
            Adres in de code
            <select bind:value={host}>
              {#each info.hosts as h, i (h)}<option value={i === 0 ? undefined : h}>{h}{i === 0 ? " (vindt je computer ook als het adres verandert)" : ""}</option>{/each}
            </select>
          </label>
        {/if}
      </div>
    {/if}

    <p class="faint note">
      De telefoon moet in hetzelfde netwerk zitten (of via een VPN zoals Tailscale; kies dan dat adres). Vraagt je
      firewall of Nook verbindingen mag ontvangen, sta dat dan toe voor je privénetwerk.
    </p>

    <h3>Pushmeldingen</h3>
    <div class="group">
      <p class="note muted">
        Pushmeldingen naar de iPhone kan deze computer nog niet sturen: daarvoor is je eigen Apple-sleutel (APNs) nodig, en dat
        stuk zit voorlopig alleen in Nook voor de Mac. Zolang de app op je telefoon openstaat, ziet hij alles meteen; Nook op
        Android meldt zelf wat er nieuw is zolang de app in het geheugen staat.
      </p>
    </div>
  {/if}
{/if}
{#if error}<p class="err">{error}</p>{/if}

<style>
  .device { display: flex; flex-direction: column; gap: 2px; }
  .small { font-size: 11px; }
  .status { justify-content: flex-start; }
  .pairing { display: flex; gap: 16px; align-items: flex-start; margin-top: 14px; flex-wrap: wrap; }
  .qr { width: 200px; height: 200px; flex: none; background: #fff; border-radius: 12px; overflow: hidden; }
  .qr :global(svg) { width: 100%; height: 100%; display: block; }
  .steps { flex: 1; min-width: 220px; display: flex; flex-direction: column; gap: 10px; }
  .steps p { margin: 0; }
  .link { font-family: var(--mono); font-size: 11px; word-break: break-all; user-select: text; background: var(--field); border: 1px solid var(--line2); border-radius: 8px; padding: 6px 8px; }
  .pairrow { margin-top: 14px; }
</style>
