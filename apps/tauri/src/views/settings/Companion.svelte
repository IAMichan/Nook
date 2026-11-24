<script lang="ts">
  // Companion: een telefoon (de iPhone-app, of Nook op Android) koppelen met deze computer, 1-op-1 met Instellingen ›
  // iPhone op de Mac (`CompanionSettings.swift`, `ConnectionRow.swift`, `CompanionSetupSheets.swift`).
  import { companion, type CompanionInfo, type PairedDeviceView } from "../../lib/companion";
  import { locale, tr } from "../../lib/i18n.svelte";
  import { relativeTime } from "../../lib/state.svelte";
  import { toast } from "../../lib/toast.svelte";
  import Dialog from "../../components/ui/Dialog.svelte";
  import DisclosureChevron from "../../components/ui/DisclosureChevron.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Menu from "../../components/ui/Menu.svelte";
  import CompanionAway from "./CompanionAway.svelte";
  import CompanionPush from "./CompanionPush.svelte";
  import CompanionScopes from "./CompanionScopes.svelte";
  import Fold from "./Fold.svelte";
  import PairPhoneSheet from "./PairPhoneSheet.svelte";

  let info = $state<CompanionInfo | null>(null);
  let error = $state<string | null>(null);
  let pairing = $state(false);
  let openIds = $state<Record<string, boolean>>({});
  let menuFor = $state<{ device: PairedDeviceView; anchor: DOMRect } | null>(null);
  let confirmUnpair = $state<PairedDeviceView | null>(null);

  async function run(f: () => Promise<CompanionInfo>) {
    error = null;
    try {
      const next = await f();
      info = next;
      if (!next.enabled) pairing = false;
    } catch (e) {
      error = String(e);
    }
  }

  $effect(() => {
    void run(companion.info);
  });

  const listening = $derived(info?.state?.state === "listening");
  const awaySummary = $derived.by(() => {
    const away = info?.away;
    if (!away || !away.relay.enabled) return tr("Alleen thuisnetwerk", "Home network only");
    if (away.relayStatus.state === "connected") return tr("Relay verbonden", "Relay connected");
    if (away.relayStatus.state === "failed") return tr("Relay werkt niet", "Relay not working");
    return tr("Relay aan", "Relay on");
  });

  function toggleOpen(id: string) {
    openIds = { ...openIds, [id]: !openIds[id] };
  }

  function openMenu(device: PairedDeviceView, e: MouseEvent) {
    e.stopPropagation();
    menuFor = { device, anchor: (e.currentTarget as HTMLElement).getBoundingClientRect() };
  }

  function lastSeenLine(device: PairedDeviceView): string {
    return device.lastSeen
      ? tr("Laatst gezien: {when}", "Last seen: {when}", { when: relativeTime(device.lastSeen) })
      : tr("Nog niet verbonden", "Not connected yet");
  }

  function statusLine(device: PairedDeviceView): string {
    const state = device.outdated ? tr("Update nodig", "Needs an update") : tr("Gekoppeld", "Paired");
    return `${state} · ${lastSeenLine(device)}`;
  }

  function formatPairedDate(iso: string): string {
    try {
      return new Date(iso).toLocaleString(locale(), { dateStyle: "medium", timeStyle: "short" });
    } catch {
      return iso;
    }
  }

  async function unpair(device: PairedDeviceView) {
    await run(() => companion.removeDevice(device.id));
    toast.success(tr("{name} verwijderd", "{name} removed", { name: device.name }));
  }
</script>

<!-- The Mac's Devices › iPhone (`CompanionSettingsRows`): title, explanation, switch and status, paired phones list
     with "+ Pair" sheet, notifications (including "Send through" segmented picker), and folded "Away from home". -->
<h3>{tr("Telefoon", "Phone")}</h3>
<p class="section-info">
  {tr(
    "Laat een gekoppelde telefoon in je eigen wifi zien welke sessies je nodig hebben, en laat je goedkeuren, antwoorden, een bericht sturen of stoppen. Werkt met Nook Companion op de iPhone en met Nook op Android. Alles gaat versleuteld; riskante goedkeuringen (zoals onbekende commando’s) kun je vanaf de telefoon alleen weigeren.",
    "Let a paired phone on your own Wi-Fi show which sessions need you, and let you approve, answer, send a message or stop. Works with Nook Companion on iPhone and with Nook on Android. Everything is encrypted; risky approvals (like unknown commands) can only be denied from the phone.",
  )}
</p>

{#if info}
  <div class="group">
    <label class="row">
      <span>{tr("Companion op je telefoon", "Companion on your phone")}</span>
      <input
        type="checkbox"
        role="switch"
        checked={info.enabled}
        onchange={(e) => run(() => companion.setEnabled(e.currentTarget.checked))}
      />
    </label>
    {#if info.enabled}
      <div class="row status">
        {#if info.state?.state === "listening"}
          <div class="status-lines">
            <span class="ok">
              {tr("Luistert op poort {port} in je lokale netwerk als {name}.", "Listening on port {port} in your local network as {name}.", {
                port: info.state.port,
                name: info.computerName,
              })}
            </span>
            {#if info.hosts.length > 0}
              <span class="faint small">{tr("Bereikbaar op {hosts}.", "Reachable at {hosts}.", { hosts: info.hosts.join(", ") })}</span>
            {/if}
          </div>
        {:else if info.state?.state === "failed"}
          <span class="err">{tr("Kan niet starten: {message}", "Can't start: {message}", { message: info.state.message })}</span>
        {:else}
          <span class="faint">{tr("Start…", "Starting…")}</span>
        {/if}
      </div>
    {/if}
  </div>

  {#if info.enabled}
    <div class="section-head">
      <h3>{tr("Gekoppelde telefoons", "Paired phones")}</h3>
      <button type="button" class="head-action" disabled={!listening} onclick={() => (pairing = true)}>
        <Ico name="plus" size={14} />{tr("Koppel een telefoon", "Pair a phone")}
      </button>
    </div>
    <div class="group">
      {#each info.devices as device (device.id)}
        {@const isOpen = !!openIds[device.id]}
        <div class="conn-row">
          <div
            class="conn-head"
            role="button"
            tabindex="0"
            aria-expanded={isOpen}
            onclick={() => toggleOpen(device.id)}
            onkeydown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), toggleOpen(device.id))}
          >
            <span class="conn-ico" aria-hidden="true"><Ico name="smartphone" size={16} /></span>
            <div class="conn-main">
              <div class="conn-top">
                <span class="conn-title">{device.name}</span>
                {#if device.appVersion}<span class="conn-ver">{device.appVersion}</span>{/if}
              </div>
              <div class="conn-sub" class:attention={device.outdated}>
                {#if device.outdated}<span class="status-dot" aria-hidden="true"></span>{/if}
                <span class="conn-sub-text">{statusLine(device)}</span>
              </div>
            </div>
            <div class="conn-trail">
              <button
                type="button"
                class="more-btn"
                title={tr("Meer", "More")}
                aria-label={tr("Meer", "More")}
                onclick={(e) => openMenu(device, e)}
              >
                <Ico name="ellipsis" size={14} />
              </button>
              <DisclosureChevron open={isOpen} size={11} />
            </div>
          </div>

          {#if isOpen}
            <div class="conn-detail">
              {#if device.outdated}
                <p class="detail-note err">
                  {tr(
                    "Update nodig: de app op deze telefoon is te oud voor deze Nook. Werk Nook Companion op de iPhone of Nook op Android bij.",
                    "Needs an update: the app on this phone is too old for this Nook. Update Nook Companion on the iPhone or Nook on Android.",
                  )}
                </p>
              {:else if device.behind}
                <p class="detail-note">
                  {tr(
                    "Op deze telefoon draait een oudere versie. Werk hem bij voor pull requests, delen en de andere nieuwe onderdelen.",
                    "This phone runs an older version. Update it to use pull requests, sharing and the other new parts.",
                  )}
                </p>
              {/if}

              <div class="sheet-part">
                <div class="part-title">{tr("Wat deze telefoon mag", "What this phone may do")}</div>
                <div class="part-rows">
                  <CompanionScopes scopes={device.scopes} onchange={(s) => run(() => companion.setScopes(device.id, s))} />
                </div>
              </div>

              <div class="sheet-part">
                <div class="part-title">{tr("Details", "Details")}</div>
                <div class="detail-list">
                  <div class="detail-item">
                    <span>{tr("Laatst gezien", "Last seen")}</span>
                    <span class="detail-val">
                      {device.lastSeen ? relativeTime(device.lastSeen) : tr("Nog niet verbonden", "Not connected yet")}
                    </span>
                  </div>
                  <div class="detail-item">
                    <span>{tr("Gekoppeld op", "Paired on")}</span>
                    <span class="detail-val">{formatPairedDate(device.pairedAt)}</span>
                  </div>
                  <div class="detail-item">
                    <span>{tr("Appversie", "App version")}</span>
                    <span class="detail-val" class:mono={!!device.appVersion}>
                      {device.appVersion ?? tr("Nog niet bekend", "Not known yet")}
                    </span>
                  </div>
                  <div class="detail-item">
                    <span>{tr("Meldingen", "Notifications")}</span>
                    <span class="detail-val">
                      {device.push
                        ? tr("Toegestaan op de telefoon", "Allowed on the phone")
                        : tr("Niet toegestaan op de telefoon", "Not allowed on the phone")}
                    </span>
                  </div>
                </div>
              </div>

              <div class="detail-foot">
                <button type="button" class="danger-btn" onclick={() => (confirmUnpair = device)}>
                  {tr("Ontkoppel", "Unpair")}
                </button>
              </div>
            </div>
          {/if}
        </div>
      {:else}
        <div class="empty">
          <strong>{tr("Nog geen telefoon gekoppeld", "No phone paired yet")}</strong>
          <span>
            {tr(
              "Een gekoppelde telefoon ziet welke sessies je nodig hebben en kan ze goedkeuren, beantwoorden of stoppen. Koppel er een met de knop rechtsboven.",
              "A paired phone sees which sessions need you and can approve, answer or stop them. Pair one with the button above.",
            )}
          </span>
        </div>
      {/each}
    </div>

    <h3>{tr("Meldingen op je telefoon", "Notifications on your phone")}</h3>
    {#if info.push}<CompanionPush {info} onchange={(i) => (info = i)} />{/if}

    {#if info.away}
      <Fold
        keys={[
          tr("Bereik deze computer buiten de deur", "Reach this computer away from home"),
          tr("Relay", "Relay"),
          tr("Houd deze computer wakker", "Keep this computer awake"),
        ]}
        title={tr("Buiten de deur", "Away from home")}
        summary={awaySummary}
      >
        <CompanionAway {info} onchange={(i) => (info = i)} />
      </Fold>
    {/if}
  {/if}
{/if}

{#if error}<p class="err">{error}</p>{/if}

{#if pairing && info}
  <PairPhoneSheet {info} onchange={(i) => (info = i)} onclose={() => (pairing = false)} />
{/if}

{#if menuFor}
  {@const target = menuFor.device}
  {@const targetOpen = !!openIds[target.id]}
  <Menu
    anchor={menuFor.anchor}
    sections={[
      [
        {
          label: targetOpen ? tr("Inklappen", "Close") : tr("Beheren", "Manage"),
          onselect: () => toggleOpen(target.id),
        },
      ],
      [
        {
          label: `${tr("Ontkoppel", "Unpair")}…`,
          destructive: true,
          onselect: () => (confirmUnpair = target),
        },
      ],
    ]}
    onclose={() => (menuFor = null)}
  />
{/if}

{#if confirmUnpair}
  {@const target = confirmUnpair}
  <Dialog
    title={tr("“{name}” ontkoppelen?", "Unpair “{name}”?", { name: target.name })}
    message={tr(
      "Deze computer vergeet de sleutel van de telefoon: die kan je sessies niet meer zien of beantwoorden tot je hem opnieuw koppelt.",
      "This computer forgets the phone's key: it can no longer see or answer your sessions until you pair it again.",
    )}
    buttons={[
      { label: tr("Ontkoppel", "Unpair"), destructive: true, onselect: () => void unpair(target) },
      { label: tr("Annuleren", "Cancel"), onselect: () => {} },
    ]}
    onclose={() => (confirmUnpair = null)}
  />
{/if}

<style>
  .status { justify-content: flex-start; }
  .status-lines { display: flex; flex-direction: column; gap: var(--space-4); }
  .ok { font: var(--text-detail); line-height: 1.35; color: var(--mint); }
  .small { font: var(--text-detail); line-height: 1.3; }
  .mono { font-family: var(--mono); }

  .empty { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16) 0; }
  .empty strong { font: var(--text-emphasis); color: var(--paper); }
  .empty span { font: var(--text-detail); line-height: 1.4; color: var(--text2); }

  /* Paired phone row (`ConnectionRow` on the Mac): icon, name + version, status + last seen, "…" menu and chevron. */
  .conn-row { border-bottom: 1px solid var(--separator); }
  .conn-row:last-child { border-bottom: none; }
  .conn-head {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    padding: var(--row-pad-y) 0;
    cursor: pointer;
    user-select: none;
  }
  .conn-head:focus-visible { outline: 2px solid var(--iris); outline-offset: -2px; border-radius: var(--radius-control); }
  .conn-ico {
    width: 28px;
    height: 28px;
    flex: none;
    display: grid;
    place-items: center;
    color: var(--text2);
  }
  .conn-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .conn-top { display: flex; align-items: baseline; gap: var(--space-8); min-width: 0; }
  .conn-title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .conn-ver { font: var(--text-caption); font-family: var(--mono); color: var(--text3); flex: none; }
  .conn-sub { display: flex; align-items: center; gap: var(--space-6); font: var(--text-detail); color: var(--text2); min-width: 0; }
  .conn-sub.attention { color: var(--coral); }
  .conn-sub-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .status-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--coral); flex: none; }

  .conn-trail { display: inline-flex; align-items: center; gap: var(--space-8); flex: none; }
  .more-btn {
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text2);
    display: grid;
    place-items: center;
    cursor: pointer;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .more-btn:hover { background: var(--row-hover); color: var(--paper); }

  /* Expanded row content (`ConnectionRow.expanded` + embedded `SheetPart`s), indented past the 28 px icon. */
  .conn-detail {
    display: flex;
    flex-direction: column;
    gap: var(--space-16);
    padding: var(--space-4) 0 var(--space-16) calc(28px + var(--space-12));
  }
  .detail-note { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .detail-note.err { color: var(--coral); }

  .sheet-part { display: flex; flex-direction: column; gap: var(--space-8); }
  .part-title { font: var(--text-emphasis); color: var(--paper); }
  .part-rows :global(.row) { padding: var(--space-8) 0; }

  .detail-list { display: flex; flex-direction: column; gap: var(--space-8); }
  .detail-item {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: var(--space-16);
    font: var(--text-body);
    color: var(--paper);
  }
  .detail-val { font: var(--text-detail); color: var(--text2); text-align: right; }

  .detail-foot { display: flex; justify-content: flex-end; padding-top: var(--space-4); }
  .danger-btn {
    height: 24px;
    padding: 0 var(--space-12);
    border: 1px solid color-mix(in srgb, var(--coral) 35%, transparent);
    border-radius: var(--radius-chip);
    background: color-mix(in srgb, var(--coral) 12%, transparent);
    color: var(--coral);
    font: var(--text-control);
    cursor: pointer;
    transition: background var(--motion-quick);
  }
  .danger-btn:hover { background: color-mix(in srgb, var(--coral) 20%, transparent); }
</style>
