<script lang="ts">
  // Companion: een telefoon (de iPhone-app, of Nook op Android) koppelen met deze computer, zoals op de Mac
  // (Instellingen › iPhone-metgezel). Aanzetten, een code tonen die vijf minuten en één keer werkt, toestellen weghalen.
  import { companion, type CompanionInfo } from "../../lib/companion";
  import { relativeTime } from "../../lib/state.svelte";
  import CompanionPush from "./CompanionPush.svelte";
  import { tr } from "../../lib/i18n.svelte";

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
      error = tr("Kopiëren lukte niet; selecteer de link en kopieer hem zelf.", "Copying didn't work; select the link and copy it yourself.");
    }
  }
</script>

<h2>{tr("Companion", "Companion")}</h2>
<p class="muted">
  {tr(
    "Laat een gekoppelde telefoon in je eigen wifi zien welke sessies je nodig hebben, en laat je goedkeuren, antwoorden, een bericht sturen of stoppen. Werkt met Nook Companion op de iPhone en met Nook op Android. Alles gaat versleuteld; riskante goedkeuringen (zoals onbekende commando’s) kun je vanaf de telefoon alleen weigeren.",
    "Let a paired phone on your own Wi-Fi show which sessions need you, and let you approve, answer, send a message or stop. Works with Nook Companion on iPhone and with Nook on Android. Everything is encrypted; risky approvals (like unknown commands) can only be denied from the phone.",
  )}
</p>

{#if info}
  <div class="group">
    <label class="row">
      <span>{tr("Companion op je telefoon", "Companion on your phone")}</span>
      <input type="checkbox" checked={info.enabled} onchange={(e) => run(() => companion.setEnabled(e.currentTarget.checked))} />
    </label>
    {#if info.enabled}
      <div class="row status">
        {#if info.state?.state === "listening"}
          <span class="muted">{tr("Luistert op poort {port} in je lokale netwerk als {name}.", "Listening on port {port} in your local network as {name}.", { port: info.state.port, name: info.computerName })}</span>
        {:else if info.state?.state === "failed"}
          <span class="err">{tr("Kan niet starten: {message}", "Can't start: {message}", { message: info.state.message })}</span>
        {:else}
          <span class="faint">{tr("Start…", "Starting…")}</span>
        {/if}
      </div>
    {/if}
  </div>

  {#if info.enabled}
    <h3>{tr("Gekoppelde telefoons", "Paired phones")}</h3>
    <div class="group">
      {#each info.devices as device (device.id)}
        <div class="row">
          <div class="device">
            <span>📱 {device.name}</span>
            <span class="faint small">{device.lastSeen ? tr("Laatst gezien: {when}", "Last seen: {when}", { when: relativeTime(device.lastSeen) }) : tr("Nog niet verbonden", "Not connected yet")}</span>
          </div>
          <button onclick={() => run(() => companion.removeDevice(device.id))}>{tr("Ontkoppel", "Unpair")}</button>
        </div>
      {:else}
        <p class="faint note">{tr("Nog geen telefoon gekoppeld.", "No phone paired yet.")}</p>
      {/each}
    </div>

    {#if info.pairing}
      <div class="pairing">
        <div class="qr" role="img" aria-label={tr("QR-code om te koppelen", "QR code to pair")}>{@html info.pairing.qrSvg}</div>
        <div class="steps">
          <p>{minutesLeft === 1 ? tr("Open Nook Companion op je iPhone, of Nook op Android › Companion, en scan deze code of plak de link. De code werkt nog 1 minuut en één keer.", "Open Nook Companion on your iPhone, or Nook on Android › Companion, and scan this code or paste the link. The code works for 1 more minute and only once.") : tr("Open Nook Companion op je iPhone, of Nook op Android › Companion, en scan deze code of plak de link. De code werkt nog {n} minuten en één keer.", "Open Nook Companion on your iPhone, or Nook on Android › Companion, and scan this code or paste the link. The code works for {n} more minutes and only once.", { n: minutesLeft })}</p>
          <code class="link">{info.pairing.url}</code>
          <div class="inline">
            <button onclick={copy}>{copied ? tr("Gekopieerd", "Copied") : tr("Kopieer link", "Copy link")}</button>
            <button class="ghost" onclick={() => { copied = false; run(companion.cancelPairing); }}>{tr("Stop koppelen", "Stop pairing")}</button>
          </div>
        </div>
      </div>
    {:else}
      <div class="inline pairrow">
        <button class="primary" disabled={!listening} onclick={() => { copied = false; run(() => companion.beginPairing(host)); }}>{tr("Koppel een telefoon", "Pair a phone")}</button>
        {#if info.hosts.length > 1}
          <label class="inline faint">
            {tr("Adres in de code", "Address in the code")}
            <select bind:value={host}>
              {#each info.hosts as h, i (h)}<option value={i === 0 ? undefined : h}>{h}{i === 0 ? " " + tr("(vindt je computer ook als het adres verandert)", "(finds your computer even when the address changes)") : ""}</option>{/each}
            </select>
          </label>
        {/if}
      </div>
    {/if}

    <p class="faint note">
      {tr(
        "De telefoon moet in hetzelfde netwerk zitten (of via een VPN zoals Tailscale; kies dan dat adres). Vraagt je firewall of Nook verbindingen mag ontvangen, sta dat dan toe voor je privénetwerk.",
        "The phone has to be on the same network (or through a VPN like Tailscale; then pick that address). If your firewall asks whether Nook may receive connections, allow it for your private network.",
      )}
    </p>

    <h3>{tr("Meldingen op de iPhone", "Notifications on iPhone")}</h3>
    {#if info.push}<CompanionPush {info} onchange={(i) => (info = i)} />{/if}
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
