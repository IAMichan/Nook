<script lang="ts">
  // Pairing a new phone in the Mac's four numbered steps (`PairPhoneSheet` in `CompanionSetupSheets.swift`):
  // 1. Open/install Nook Companion, 2. Choose what it may do, 3. Scan the QR code (or copy the link), 4. Wait for the
  // phone to arrive. Closing before a phone scans cancels the active pairing window.
  import { untrack } from "svelte";
  import { companion, type CompanionInfo, type CompanionScope, type PairedDeviceView } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import QRCodeView from "../../components/ui/QRCodeView.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import { setupCheck, type SetupCheckState } from "../../components/ui/setup-check";
  import Spinner from "../../components/ui/Spinner.svelte";
  import CompanionScopes from "./CompanionScopes.svelte";
  import SettingsTile from "./SettingsTile.svelte";

  let { info, onchange, onclose }: {
    info: CompanionInfo;
    onchange: (info: CompanionInfo) => void;
    onclose: () => void;
  } = $props();

  const initialIds = new Set(untrack(() => info.devices.map((d) => d.id)));
  let paired = $state<PairedDeviceView | null>(null);
  let host = $state<string | undefined>(undefined);
  let copied = $state(false);
  let copyTimer: ReturnType<typeof setTimeout> | undefined;
  let starting = $state(false);
  let error = $state<string | null>(null);
  let closed = false;

  const listening = $derived(info.state?.state === "listening");
  const minutesLeft = $derived(
    info.pairing ? Math.max(0, Math.ceil((new Date(info.pairing.until).getTime() - Date.now()) / 60000)) : 0,
  );

  const waitState = $derived<SetupCheckState>(
    paired
      ? setupCheck.passed(tr("{name} is gekoppeld.", "{name} is paired.", { name: paired.name }))
      : info.pairing
        ? setupCheck.checking()
        : setupCheck.idle(),
  );

  async function begin(selectedHost?: string) {
    starting = true;
    error = null;
    copied = false;
    try {
      onchange(await companion.beginPairing(selectedHost));
    } catch (e) {
      error = String(e);
    } finally {
      starting = false;
    }
  }

  // Generate a pairing code as soon as the computer is listening (and again if it starts listening while open).
  $effect(() => {
    if (!listening || paired || info.pairing) return;
    untrack(() => {
      if (!starting && !error) void begin(host);
    });
  });

  // Detect the phone that just paired through this sheet, announce it, and mark step 3 & 4 done.
  $effect(() => {
    if (paired) return;
    const added = info.devices.find((d) => !initialIds.has(d.id));
    if (!added) return;
    paired = added;
    toast.success(tr("{name} toegevoegd", "{name} added", { name: added.name }));
  });

  // While waiting for the phone to scan, poll so arrival and expiry show up immediately.
  $effect(() => {
    if (paired) return;
    const t = setInterval(async () => {
      try {
        onchange(await companion.info());
      } catch {
        // Ignore transient poll errors while the sheet stays open.
      }
    }, 2000);
    return () => clearInterval(t);
  });

  // Closing before a phone paired cancels the pairing window on the server too.
  $effect(() => {
    return () => {
      clearTimeout(copyTimer);
      if (!paired && !closed && info.pairing) {
        companion.cancelPairing().then(onchange).catch(() => {});
      }
    };
  });

  function close() {
    if (closed) return;
    closed = true;
    if (!paired && info.pairing) {
      companion.cancelPairing().then(onchange).catch(() => {});
    }
    onclose();
  }

  async function setPendingScopes(scopes: CompanionScope[]) {
    error = null;
    try {
      onchange(await companion.setScopes(null, scopes));
    } catch (e) {
      error = String(e);
    }
  }

  function pickHost(e: Event) {
    const val = (e.currentTarget as HTMLSelectElement).value;
    host = val || undefined;
    void begin(host);
  }

  async function copy() {
    if (!info.pairing) return;
    try {
      await navigator.clipboard.writeText(info.pairing.url);
      copied = true;
      clearTimeout(copyTimer);
      copyTimer = setTimeout(() => (copied = false), 2000);
    } catch {
      error = tr(
        "Kopiëren lukte niet; selecteer de link en kopieer hem zelf.",
        "Copying didn't work; select the link and copy it yourself.",
      );
    }
  }
</script>

<SetupSheet
  title={tr("Nieuwe telefoon koppelen", "Pair a new phone")}
  subtitle={tr(
    "Koppel een telefoon aan deze computer om je sessies ermee te volgen en te sturen.",
    "Pair a phone with this computer to follow and steer your sessions from it.",
  )}
  onclose={close}
>
  {#snippet icon()}
    <SettingsTile section="iphone" size={40} />
  {/snippet}

  <SetupStep number={1} title={tr("Open Nook Companion op je telefoon", "Open Nook Companion on your phone")}>
    <p class="step-note">
      {tr(
        "Installeer Nook Companion op je iPhone of Nook op Android als die er nog niet staat, en houd je telefoon tijdens het koppelen in hetzelfde netwerk als deze computer (of via een VPN zoals Tailscale). Vraagt je firewall of Nook verbindingen mag ontvangen, sta dat dan toe voor je privénetwerk.",
        "Install Nook Companion on your iPhone or Nook on Android if it is not there yet, and keep your phone on the same network as this computer while pairing (or through a VPN like Tailscale). If your firewall asks whether Nook may receive connections, allow it for your private network.",
      )}
    </p>
  </SetupStep>

  <SetupStep number={2} title={tr("Kies wat hij mag", "Choose what it may do")}>
    <div class="step-scopes">
      <CompanionScopes scopes={info.pendingScopes} onchange={setPendingScopes} />
    </div>
  </SetupStep>

  <SetupStep number={3} title={tr("Scan de code", "Scan the code")} done={!!paired}>
    {#if !paired}
      {#if info.pairing}
        <div class="qr-block">
          <QRCodeView svg={info.pairing.qrSvg} label={tr("QR-code om te koppelen", "QR code to pair")} size={148} />
          <div class="qr-details">
            <p class="step-note">
              {minutesLeft === 1
                ? tr(
                    "Open Nook Companion op je iPhone, of Nook op Android › Companion, en scan deze code of plak de link. De code werkt nog 1 minuut en één keer.",
                    "Open Nook Companion on your iPhone, or Nook on Android › Companion, and scan this code or paste the link. The code works for 1 more minute and only once.",
                  )
                : tr(
                    "Open Nook Companion op je iPhone, of Nook op Android › Companion, en scan deze code of plak de link. De code werkt nog {n} minuten en één keer.",
                    "Open Nook Companion on your iPhone, or Nook on Android › Companion, and scan this code or paste the link. The code works for {n} more minutes and only once.",
                    { n: minutesLeft },
                  )}
            </p>
            <code class="link">{info.pairing.url}</code>
            <div class="qr-actions">
              <button type="button" class="step-btn" onclick={copy}>
                {copied ? tr("Gekopieerd", "Copied") : tr("Kopieer link", "Copy link")}
              </button>
            </div>
          </div>
        </div>
        {#if info.hosts.length > 1}
          <label class="host-row">
            <span class="step-note">{tr("Adres in de code", "Address in the code")}</span>
            <select value={host ?? ""} onchange={pickHost}>
              {#each info.hosts as h, i (h)}
                <option value={i === 0 ? "" : h}>
                  {h}{i === 0 ? " " + tr("(vindt je computer ook als het adres verandert)", "(finds your computer even when the address changes)") : ""}
                </option>
              {/each}
            </select>
          </label>
        {/if}
      {:else if listening && starting}
        <div class="checking"><Spinner size={12} /><span>{tr("Start…", "Starting…")}</span></div>
      {:else if listening}
        <button type="button" class="step-btn" onclick={() => begin(host)}>{tr("Koppel een telefoon", "Pair a phone")}</button>
      {:else}
        <p class="step-note">
          {tr(
            "De code verschijnt zodra deze computer naar de telefoon luistert.",
            "The code can be shown once this computer listens for the phone.",
          )}
        </p>
      {/if}
    {/if}
  </SetupStep>

  <SetupCheckStep
    number={4}
    title={tr("Wacht op de telefoon", "Wait for the phone")}
    detail={tr(
      "Zodra de telefoon de code scant, zet Nook hem bij je gekoppelde telefoons.",
      "As soon as the phone scans the code, Nook adds it to your paired phones.",
    )}
    checkingLabel={tr(
      "Zodra de telefoon de code scant, zet Nook hem bij je gekoppelde telefoons.",
      "As soon as the phone scans the code, Nook adds it to your paired phones.",
    )}
    state={waitState}
  />

  {#if error}<p class="step-note err">{error}</p>{/if}

  {#snippet footer()}
    <span class="spacer"></span>
    <button type="button" class="primary" onclick={close}>{tr("Klaar", "Done")}</button>
  {/snippet}
</SetupSheet>

<style>
  .step-note { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .step-note.err { color: var(--coral); }

  .step-scopes {
    width: 100%;
    background: var(--surface);
    border: 1px solid var(--separator);
    border-radius: var(--radius-card);
    padding: 0 var(--space-12);
  }
  .step-scopes :global(.row) { padding: var(--space-8) 0; }

  .qr-block { display: flex; align-items: flex-start; gap: var(--space-16); flex-wrap: wrap; width: 100%; }
  .qr-details { flex: 1; min-width: 200px; display: flex; flex-direction: column; gap: var(--space-8); }
  .link {
    font: var(--text-code);
    word-break: break-all;
    user-select: text;
    background: var(--field);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    padding: var(--space-6) var(--space-8);
    color: var(--text-strong);
  }
  .qr-actions { display: flex; align-items: center; gap: var(--space-8); }
  .step-btn {
    align-self: flex-start;
    height: 28px;
    padding: 0 var(--space-12);
    border: none;
    border-radius: var(--radius-control);
    background: var(--smoke);
    color: var(--paper);
    font: var(--text-control);
    cursor: pointer;
    transition: background var(--motion-quick);
  }
  .step-btn:hover { background: var(--line2); }

  .host-row { display: flex; flex-direction: column; gap: var(--space-6); width: 100%; }
  .host-row select { align-self: flex-start; max-width: 100%; }

  .checking { display: flex; align-items: flex-start; gap: var(--space-8); font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .spacer { flex: 1; }
</style>
