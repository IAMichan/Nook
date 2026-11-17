<script lang="ts">
  // Settings, as the iPhone's sheet (`SettingsView`): your Mac and how the phone reaches it, what this phone does, the
  // plan limits, pairing, and the versions. On Android it also offers Nook on this phone itself.
  import { onMount } from "svelte";
  import { companion, computerChoices, computerIcon, computerStatus, fallbackComputerName, has, may, resetsIn, routeWords, Feature, type ClientView, type UsageAccount } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import PanelHeader from "./ui/PanelHeader.svelte";
  import ConnectionLine from "./ui/ConnectionLine.svelte";
  import SettingsRow from "./ui/SettingsRow.svelte";
  import Toggle from "./ui/Toggle.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import Dialog from "./ui/Dialog.svelte";

  let { view, took, onclose, onlocal, onswitch, onadd }: {
    view: ClientView; took: (v: ClientView) => void; onclose: () => void; onlocal?: () => void; onswitch?: (id: string) => void; onadd?: () => void;
  } = $props();
  const routeLine = $derived(view.phase === "connected" ? (routeWords(view.route)?.text ?? tr("Verbonden", "Connected")) : tr("Niet verbonden", "Not connected"));
  let steer = $state(readSteer());
  let usage = $state<{ accounts: UsageAccount[]; sessions: number; completed: number; running: number; failed: number } | null>(null);
  let usageLoading = $state(false);
  const activePlatform = $derived(view.macs?.find((m) => m.active)?.platform);
  let confirmUnpair = $state(false);
  let version = $state("");
  let checking = $state(false);

  function readSteer(): boolean {
    try { return localStorage.getItem("companion.steer") === "1"; } catch { return false; }
  }
  function setSteer(on: boolean) {
    haptic();
    steer = on;
    try { localStorage.setItem("companion.steer", on ? "1" : "0"); } catch { /* remembered for this visit */ }
  }

  onMount(async () => {
    try { version = await (await import("@tauri-apps/api/app")).getVersion(); } catch { /* not in the app */ }
    if (has(view, Feature.usage) && may(view, "read")) {
      usageLoading = true;
      const r = await companion.call({ op: "usage", item: "today" });
      const u = (r.response as { usage?: typeof usage } | null)?.usage;
      if (u) usage = u;
      usageLoading = false;
    }
  });

  async function check() {
    checking = true;
    took(await companion.refresh());
    checking = false;
  }
</script>

<div class="settings">
  <div class="scroll">
    <PanelHeader title={tr("Instellingen", "Settings")} {view} onclose={onclose} />
    <div class="groups">
      <ConnectionLine {view} />
      <section>
        <h3>{(view.macs?.length ?? 0) > 1 ? tr("Computers", "Computers") : fallbackComputerName(activePlatform, true)}</h3>
        <div class="card">
          <SettingsRow icon={computerIcon(activePlatform)} title={view.macName || fallbackComputerName(activePlatform, true)} detail={routeLine}>
            {#snippet trailing()}<span class="dot" style:background={view.phase === "connected" ? "var(--mint)" : "var(--amber)"}></span>{/snippet}
          </SettingsRow>
          {#each computerChoices(view).filter((m) => !m.active) as m (m.id)}
            <SettingsRow icon={computerIcon(m.platform)} title={tr("Overschakelen naar {name}", "Switch to {name}", { name: m.name })} detail={computerStatus(m) || undefined} onclick={() => onswitch?.(m.id)} />
          {/each}
          <SettingsRow icon="stethoscope" title={checking ? tr("Controleren…", "Checking…") : tr("Controleer de verbinding", "Check the connection")} detail={view.phase === "offline" ? view.reason : undefined} onclick={check} />
        </div>
      </section>
      <section>
        <h3>{tr("Op deze iPhone", "On this phone")}</h3>
        <div class="card">
          {#if has(view, Feature.steer)}
            <SettingsRow icon="corner-down-right" title={tr("Een werkende agent direct bijsturen", "Steer a working agent right away")} detail={tr("Uit: je bericht wacht tot de beurt klaar is.", "Off: your message waits until the turn ends.")}>
              {#snippet trailing()}<Toggle on={steer} onchange={setSteer} label={tr("Een werkende agent direct bijsturen", "Steer a working agent right away")} />{/snippet}
            </SettingsRow>
          {/if}
          <SettingsRow icon="bell" title={tr("Meldingen", "Notifications")} detail={tr("Van je Mac, ook buitenshuis.", "From your Mac, also away from home.")} />
          {#if onlocal}
            <SettingsRow icon="smartphone" title={tr("Nook op deze telefoon", "Nook on this phone")} detail={tr("Nooks eigen brein op je telefoon, zonder je Mac.", "Nook's own brain on your phone, without your Mac.")} onclick={onlocal} />
          {/if}
        </div>
      </section>
      {#if has(view, Feature.usage) && may(view, "read")}
        <section>
          <h3>{tr("Gebruik", "Usage")}</h3>
          <div class="card">
            {#if usageLoading}
              <SettingsRow icon="chart-column" title={tr("Laden…", "Loading…")} />
            {:else if !usage?.accounts.length}
              <SettingsRow icon="chart-column" title={tr("Geen limieten gemeld", "No plan limits reported")} />
            {:else}
              {#each usage.accounts as a (a.id)}
                <div class="account">
                  <span class="ahead"><AgentMark agent={a.agent} size={28} /><span>{a.agent}{a.account ? ` · ${a.account}` : ""}</span></span>
                  {#each a.limits as l (l.label)}
                    <div class="limit">
                      <span class="lrow"><span>{l.label}</span><span>{Math.round(l.percent)}%</span></span>
                      <span class="bar"><span style:width="{Math.min(100, l.percent)}%" style:background={l.percent >= 80 ? "var(--amber)" : "var(--iris)"}></span></span>
                      <small>{l.note ?? (l.resetsAt ? tr("Reset {when}", "Resets {when}", { when: resetsIn(l.resetsAt) }) : "")}</small>
                    </div>
                  {/each}
                </div>
              {/each}
            {/if}
            {#if usage}
              <SettingsRow icon="layers" title={tr("{n} sessies vandaag", "{n} sessions today", { n: usage.sessions })} detail={tr("{a} klaar · {b} bezig · {c} mislukt", "{a} done · {b} working · {c} failed", { a: usage.completed, b: usage.running, c: usage.failed })} />
            {/if}
          </div>
        </section>
      {/if}
      <section>
        <h3>{tr("Koppelen", "Pairing")}</h3>
        <div class="card">
          {#if onadd}<SettingsRow icon="plus" title={tr("Koppel nog een computer", "Pair another computer")} onclick={onadd} />{/if}
          <SettingsRow icon="circle-x" title={tr("Ontkoppel van deze computer", "Unpair from this computer")} destructive onclick={() => (confirmUnpair = true)} />
        </div>
      </section>
      <section>
        <h3>{tr("Over", "About")}</h3>
        <div class="card">
          <SettingsRow icon="info" title="Nook" detail={version} />
        </div>
      </section>
    </div>
  </div>
</div>

{#if confirmUnpair}
  <Dialog title={tr("Ontkoppelen van deze computer?", "Unpair from this computer?")} message={tr("Je kunt opnieuw koppelen met de code in Nook op je computer.", "You can pair again with the code in Nook on your computer.")} onclose={() => (confirmUnpair = false)} buttons={[
    { label: tr("Ontkoppel", "Unpair"), destructive: true, onselect: async () => { took(await companion.unpair()); onclose(); } },
    { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} },
  ]} />
{/if}

<style>
  .settings { flex: 1; min-height: 0; display: flex; flex-direction: column; padding-top: 12px; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 32px; }
  .groups { display: flex; flex-direction: column; gap: 24px; padding: 0 16px; }
  section { display: flex; flex-direction: column; gap: 6px; }
  h3 { margin: 0 0 0 12px; font: var(--pt-label); color: var(--text3); }
  .card { background: var(--surface); border-radius: 16px; overflow: hidden; }
  .dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
  .account { display: flex; flex-direction: column; gap: 8px; padding: 12px 16px; }
  .ahead { display: flex; align-items: center; gap: 8px; font: var(--pt-body); color: var(--paper); }
  .limit { display: flex; flex-direction: column; gap: 4px; padding-left: 36px; }
  .lrow { display: flex; justify-content: space-between; font: var(--pt-detail); color: var(--text2); }
  .bar { height: 6px; border-radius: 999px; background: var(--well); overflow: hidden; }
  .bar span { display: block; height: 100%; border-radius: 999px; }
  small { font: var(--pt-caption); color: var(--text3); }
</style>
