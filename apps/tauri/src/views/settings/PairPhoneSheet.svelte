<script lang="ts">
  // Pairing a new phone in the Mac's four numbered steps (`PairPhoneSheet` in `CompanionSetupSheets.swift`):
  // 1. Open/install Nook Companion, 2. Choose what it may do, 3. Scan the QR code (or copy the link), 4. Wait for the
  // phone to arrive. Closing before a phone scans cancels the active pairing window.
  import { untrack } from "svelte";
  import { companion, type CompanionInfo, type CompanionScope, type PairedDeviceView } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import QRCodeView from "../../components/ui/QRCodeView.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import Spinner from "../../components/ui/Spinner.svelte";
  import CompanionScopes from "./CompanionScopes.svelte";

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

<Sheet onclose={close} label={tr("Nieuwe telefoon koppelen", "Pair a new phone")}>
  <div class="sheet-head">
    <div class="tile" aria-hidden="true"><Ico name="smartphone" size={20} /></div>
    <div class="head-text">
      <h4>{tr("Nieuwe telefoon koppelen", "Pair a new phone")}</h4>
      <p class="subtitle">
        {tr(
          "Koppel een telefoon aan deze computer om je sessies ermee te volgen en te sturen.",
          "Pair a phone with this computer to follow and steer your sessions from it.",
        )}
      </p>
    </div>
  </div>

  <div class="sheet-body">
    <div class="step">
      <span class="num" aria-hidden="true">1</span>
      <div class="step-content">
        <div class="step-title">{tr("Open Nook Companion op je telefoon", "Open Nook Companion on your phone")}</div>
        <p class="step-note">
          {tr(
            "Installeer Nook Companion op je iPhone of Nook op Android als die er nog niet staat, en houd je telefoon tijdens het koppelen in hetzelfde netwerk als deze computer (of via een VPN zoals Tailscale). Vraagt je firewall of Nook verbindingen mag ontvangen, sta dat dan toe voor je privénetwerk.",
            "Install Nook Companion on your iPhone or Nook on Android if it is not there yet, and keep your phone on the same network as this computer while pairing (or through a VPN like Tailscale). If your firewall asks whether Nook may receive connections, allow it for your private network.",
          )}
        </p>
      </div>
    </div>

    <div class="step">
      <span class="num" aria-hidden="true">2</span>
      <div class="step-content">
        <div class="step-title">{tr("Kies wat hij mag", "Choose what it may do")}</div>
        <div class="step-scopes">
          <CompanionScopes scopes={info.pendingScopes} onchange={setPendingScopes} />
        </div>
      </div>
    </div>

    <div class="step">
      <span class="num" class:done={!!paired} aria-hidden="true">
        {#if paired}<Ico name="check" size={12} stroke={2.8} />{:else}3{/if}
      </span>
      <div class="step-content">
        <div class="step-title">{tr("Scan de code", "Scan the code")}</div>
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
      </div>
    </div>

    <div class="step">
      <span class="num" class:done={!!paired} aria-hidden="true">
        {#if paired}<Ico name="check" size={12} stroke={2.8} />{:else}4{/if}
      </span>
      <div class="step-content">
        <div class="step-title">{tr("Wacht op de telefoon", "Wait for the phone")}</div>
        {#if paired}
          <p class="step-note ok">{tr("{name} is gekoppeld.", "{name} is paired.", { name: paired.name })}</p>
        {:else if info.pairing}
          <div class="checking">
            <Spinner size={12} />
            <span>
              {tr(
                "Zodra de telefoon de code scant, zet Nook hem bij je gekoppelde telefoons.",
                "As soon as the phone scans the code, Nook adds it to your paired phones.",
              )}
            </span>
          </div>
        {:else}
          <p class="step-note">
            {tr(
              "Zodra de telefoon de code scant, zet Nook hem bij je gekoppelde telefoons.",
              "As soon as the phone scans the code, Nook adds it to your paired phones.",
            )}
          </p>
        {/if}
      </div>
    </div>

    {#if error}<p class="step-note err">{error}</p>{/if}
  </div>

  <div class="sheet-foot">
    <span class="spacer"></span>
    <button type="button" class="primary" onclick={close}>{tr("Klaar", "Done")}</button>
  </div>
</Sheet>

<style>
  .sheet-head {
    display: flex;
    align-items: center;
    gap: var(--space-16);
    padding: var(--space-24);
    border-bottom: 1px solid var(--separator);
    flex: none;
  }
  .tile {
    width: 40px;
    height: 40px;
    flex: none;
    display: grid;
    place-items: center;
    border-radius: var(--radius-card);
    background: var(--smoke);
    color: var(--paper);
  }
  .head-text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  h4 { margin: 0; font: var(--text-heading); color: var(--paper); }
  .subtitle { margin: 0; font: var(--text-detail); line-height: 1.35; color: var(--text2); }

  .sheet-body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: var(--space-24);
    display: flex;
    flex-direction: column;
    gap: var(--space-24);
  }
  .step { display: flex; align-items: flex-start; gap: var(--space-16); }
  .num {
    width: 24px;
    height: 24px;
    flex: none;
    display: grid;
    place-items: center;
    border-radius: 50%;
    background: var(--iris);
    color: var(--on-iris);
    font: var(--text-label);
    font-weight: 700;
  }
  .num.done { background: var(--mint); color: var(--ink); }
  .step-content { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-12); }
  .step-title { font: var(--text-emphasis); color: var(--paper); padding-top: var(--space-2); }
  .step-note { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .step-note.ok { color: var(--mint); }
  .step-note.err { color: var(--coral); }

  .step-scopes {
    background: var(--surface);
    border: 1px solid var(--separator);
    border-radius: var(--radius-card);
    padding: 0 var(--space-12);
  }
  .step-scopes :global(.row) { padding: var(--space-8) 0; }

  .qr-block { display: flex; align-items: flex-start; gap: var(--space-16); flex-wrap: wrap; }
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

  .host-row { display: flex; flex-direction: column; gap: var(--space-6); }
  .host-row select { align-self: flex-start; max-width: 100%; }

  .checking { display: flex; align-items: flex-start; gap: var(--space-8); font: var(--text-detail); line-height: 1.4; color: var(--text2); }

  .sheet-foot {
    display: flex;
    align-items: center;
    padding: var(--space-16) var(--space-24);
    border-top: 1px solid var(--separator);
    flex: none;
  }
  .spacer { flex: 1; }
</style>
