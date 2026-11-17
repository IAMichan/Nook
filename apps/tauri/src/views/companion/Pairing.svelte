<script lang="ts">
  // Pairing, as the iPhone's first screen (`PairingView`): Nook's face, three steps, Scan the code, or paste the link.
  import { companion, looksLikePairingLink, type ClientView } from "../../lib/companion";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NookMark from "./ui/NookMark.svelte";
  import Ico from "./ui/Ico.svelte";

  let { view, onchange, adding = false, oncancel }: { view: ClientView; onchange: (v: ClientView) => void; adding?: boolean; oncancel?: () => void } = $props();
  let text = $state("");
  let pasting = $state(false);
  let scanError = $state<string | null>(null);
  const android = $derived(nook.info?.capabilities.os === "android");

  async function pair(link: string) {
    onchange({ ...view, phase: "pairing", notice: null });
    const v = await companion.pair(link.trim(), view.deviceName ?? "");
    haptic(v.phase === "connected" ? "success" : "warning");
    onchange({ ...v, deviceName: view.deviceName });
  }

  async function scan() {
    scanError = null;
    try {
      const scanner = await import("@tauri-apps/plugin-barcode-scanner");
      let permission = await scanner.checkPermissions();
      if (permission !== "granted") permission = await scanner.requestPermissions();
      if (permission !== "granted") {
        scanError = tr("Zonder toegang tot de camera kun je de link plakken.", "Without camera access you can paste the link.");
        pasting = true;
        return;
      }
      const result = await scanner.scan({ formats: [scanner.Format.QRCode], windowed: false });
      if (looksLikePairingLink(result.content)) await pair(result.content);
      else scanError = tr("Dat is geen koppelcode van Nook.", "That's not a Nook pairing code.");
    } catch (e) {
      scanError = tr("Scannen lukte niet: {error}", "Scanning didn't work: {error}", { error: String(e) });
    }
  }
  const steps = [
    tr("Open Nook op je computer: op een Mac Instellingen › iPhone-companion, op Windows of Linux Instellingen › Companion. Zet hem aan.", "Open Nook on your computer: on a Mac, Settings › iPhone companion; on Windows or Linux, Settings › Companion. Turn it on."),
    tr("Kies ‘Koppel een iPhone’ op een Mac, of ‘Koppel een telefoon’ op Windows of Linux: Nook toont vijf minuten een code.", "Choose ‘Pair an iPhone’ on a Mac, or ‘Pair a phone’ on Windows or Linux: Nook shows a code for five minutes."),
    tr("Scan hem hier. Je telefoon en computer moeten op hetzelfde wifi zitten.", "Scan it here. Your phone and computer need to be on the same Wi‑Fi."),
  ];
</script>

<div class="pairing">
  <div class="hero">
    <span class="aura"><NookMark size={72} /></span>
    <h1>{tr("Nook op je telefoon", "Nook on your phone")}</h1>
    <p>{tr("Volg je agents, keur goed wat ze vragen, start nieuw werk en chat met Nook.", "Follow your agents, approve what they ask, start new work, and chat with Nook.")}</p>
  </div>
  <ol class="steps">
    {#each steps as step, i (i)}
      <li><span class="num">{i + 1}</span><span>{step}</span></li>
    {/each}
  </ol>
  <div class="actions">
    {#if android}
      <button class="primary press" onclick={scan} disabled={view.phase === "pairing"}><Ico name="scan-qr-code" size={18} />{tr("Scan de code", "Scan the code")}</button>
    {/if}
    {#if scanError}<p class="err">{scanError}</p>{/if}
    {#if pasting || !android}
      <textarea class="link" bind:value={text} rows="3" placeholder="nook://pair?…" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>
      <button class="primary press" disabled={!text.trim() || view.phase === "pairing"} onclick={() => pair(text)}>{view.phase === "pairing" ? tr("Koppelen…", "Pairing…") : tr("Koppel", "Pair")}</button>
    {:else}
      <button class="ghost press" onclick={() => (pasting = true)}>{tr("Plak liever de link", "Paste the link instead")}</button>
    {/if}
  </div>
  {#if adding}<button class="ghost press" onclick={oncancel}>{tr("Annuleer", "Cancel")}</button>{/if}
  <p class="foot"><Ico name="shield" size={13} />{tr("Alles tussen je telefoon en je computer is end-to-end versleuteld.", "Everything between your phone and your computer is encrypted end to end.")}</p>
</div>

<style>
  .pairing { flex: 1; overflow-y: auto; padding: 56px 24px 32px; display: flex; flex-direction: column; gap: 24px; }
  .hero { display: flex; flex-direction: column; gap: 12px; }
  .aura { width: 72px; height: 72px; display: inline-flex; align-items: center; justify-content: center; position: relative; }
  .aura::before { content: ""; position: absolute; width: 240px; height: 240px; left: -84px; top: -84px; border-radius: 50%; background: radial-gradient(rgba(244, 243, 247, 0.22), rgba(244, 243, 247, 0.06) 40%, transparent 70%); pointer-events: none; }
  h1 { margin: 0; font: var(--pt-display); position: relative; }
  .hero p { margin: 0; font: var(--pt-body); color: var(--text2); position: relative; }
  .steps { list-style: none; margin: 0; padding: 16px; background: var(--surface); border-radius: 12px; display: flex; flex-direction: column; gap: 16px; position: relative; }
  .steps li { display: flex; gap: 12px; align-items: flex-start; font: var(--pt-body); color: var(--text-strong); position: relative; }
  .steps li:not(:last-child)::after { content: ""; position: absolute; left: 14px; top: 30px; bottom: -16px; width: 1px; background: var(--line2); }
  .num { width: 28px; height: 28px; border-radius: 50%; background: var(--smoke); border: 0.5px solid var(--hairline); display: inline-flex; align-items: center; justify-content: center; font: 700 13px ui-rounded, var(--font); flex: none; }
  .actions { display: flex; flex-direction: column; gap: 12px; }
  .primary { height: 50px; border-radius: 999px; background: var(--iris) !important; color: var(--on-iris) !important; font: 600 17px var(--font) !important; display: inline-flex; align-items: center; justify-content: center; gap: 8px; }
  .ghost { height: 44px; color: var(--text2) !important; font: var(--pt-control) !important; }
  .link { resize: none; padding: 10px !important; background: var(--well) !important; border-radius: 8px; font: var(--pt-code) !important; font-size: 13px !important; }
  .err { margin: 0; font: var(--pt-detail); color: var(--coral); }
  .foot { margin: 0; display: flex; align-items: baseline; gap: 6px; font: var(--pt-detail); color: var(--text3); }
</style>
