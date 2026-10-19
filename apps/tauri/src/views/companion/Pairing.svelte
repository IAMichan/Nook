<script lang="ts">
  // Koppelen met een Mac of pc: de QR-code scannen (camera) of de link plakken.
  import { companion, looksLikePairingLink, type ClientView } from "../../lib/companion";
  import { nook } from "../../lib/state.svelte";

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
        scanError = "Zonder toegang tot de camera kun je de link plakken.";
        return;
      }
      const result = await scanner.scan({ formats: [scanner.Format.QRCode], windowed: false });
      if (looksLikePairingLink(result.content)) await pair(result.content);
      else scanError = "Dat is geen koppelcode van Nook.";
    } catch (e) {
      scanError = `Scannen lukte niet: ${e}`;
    }
  }
</script>

<div class="pairing">
  <h2>Koppel met je computer</h2>
  <p class="muted">
    Zet op je Mac of pc in Nook › Instellingen de companion aan (op de Mac: iPhone-metgezel) en kies ‘Koppel een
    telefoon’. Scan dan de code, of plak de link. Je telefoon en computer moeten op hetzelfde wifi zitten.
  </p>
  {#if android}
    <button class="primary big" onclick={scan} disabled={view.phase === "pairing"}>Scan de code</button>
    {#if scanError}<p class="err">{scanError}</p>{/if}
  {/if}
  <label class="field">
    <span class="faint">Link</span>
    <textarea bind:value={text} rows="3" placeholder="nook://pair?…" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>
  </label>
  <label class="field">
    <span class="faint">Naam van deze telefoon</span>
    <input bind:value={name} maxlength="60" />
  </label>
  <button class="big" disabled={!text.trim() || view.phase === "pairing"} onclick={() => pair(text)}>
    {view.phase === "pairing" ? "Koppelen…" : "Koppel"}
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
