<script lang="ts">
  // Koppelen met een Mac of pc: de QR-code scannen (camera) of de link plakken.
  import { companion, looksLikePairingLink, type ClientView } from "../../lib/companion";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";

  let { view, onchange }: { view: ClientView; onchange: (v: ClientView) => void } = $props();
  let text = $state("");
  let name = $state("");
  let scanError = $state<string | null>(null);
  const android = $derived(nook.info?.capabilities.os === "android");

  $effect(() => {
    if (!name && view.deviceName) name = view.deviceName;
  });

  async function pair(link: string) {
    onchange({ ...view, phase: "pairing", notice: null });
    onchange({ ...(await companion.pair(link.trim(), name)), deviceName: view.deviceName });
  }

  async function scan() {
    scanError = null;
    try {
      const scanner = await import("@tauri-apps/plugin-barcode-scanner");
      let permission = await scanner.checkPermissions();
      if (permission !== "granted") permission = await scanner.requestPermissions();
      if (permission !== "granted") {
        scanError = tr("Zonder toegang tot de camera kun je de link plakken.", "Without camera access you can paste the link.");
        return;
      }
      const result = await scanner.scan({ formats: [scanner.Format.QRCode], windowed: false });
      if (looksLikePairingLink(result.content)) await pair(result.content);
      else scanError = tr("Dat is geen koppelcode van Nook.", "That's not a Nook pairing code.");
    } catch (e) {
      scanError = tr("Scannen lukte niet: {error}", "Scanning didn't work: {error}", { error: String(e) });
    }
  }
</script>

<div class="pairing">
  <h2>{tr("Koppel met je computer", "Pair with your computer")}</h2>
  <p class="muted">
    {tr("Zet op je Mac of pc in Nook › Instellingen de companion aan (op de Mac: iPhone-metgezel) en kies ‘Koppel een telefoon’. Scan dan de code, of plak de link. Je telefoon en computer moeten op hetzelfde wifi zitten.", "On your Mac or PC, turn on the companion in Nook › Settings (on the Mac: iPhone companion) and choose ‘Pair a phone’. Then scan the code, or paste the link. Your phone and computer must be on the same Wi-Fi.")}
  </p>
  {#if android}
    <button class="primary big" onclick={scan} disabled={view.phase === "pairing"}>{tr("Scan de code", "Scan the code")}</button>
    {#if scanError}<p class="err">{scanError}</p>{/if}
  {/if}
  <label class="field">
    <span class="faint">{tr("Link", "Link")}</span>
    <textarea bind:value={text} rows="3" placeholder="nook://pair?…" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>
  </label>
  <label class="field">
    <span class="faint">{tr("Naam van deze telefoon", "Name of this phone")}</span>
    <input bind:value={name} maxlength="60" />
  </label>
  <button class="big" disabled={!text.trim() || view.phase === "pairing"} onclick={() => pair(text)}>
    {view.phase === "pairing" ? tr("Koppelen…", "Pairing…") : tr("Koppel", "Pair")}
  </button>
</div>

<style>
  .pairing { padding: 20px 16px; display: flex; flex-direction: column; gap: 14px; overflow-y: auto; max-width: 560px; }
  h2 { margin: 0; font-size: 19px; }
  p { margin: 0; line-height: 1.45; }
  .field { display: flex; flex-direction: column; gap: 6px; }
  textarea { resize: none; font-family: var(--mono); font-size: 12px; }
  .big { min-height: 48px; font-size: 15px; }
  .err { color: var(--coral); }
</style>
