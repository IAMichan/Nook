<script lang="ts">
  // Setting up the user's own relay on Cloudflare (`OwnRelaySheet` in CompanionSetupSheets.swift, CO-08):
  // open Cloudflare for a scoped API token, paste it, and Nook deploys the Worker onto the account and
  // checks that this computer connects to it.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { deployStepText, normalizeRelayUrl, ownRelayCheckState } from "../../lib/cloudflare-relay";
  import { companion, type AwayInfo, type CompanionInfo } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import StepAction from "../../components/ui/StepAction.svelte";
  import Fold from "./Fold.svelte";
  import SettingNote from "./SettingNote.svelte";
  import SettingsTile from "./SettingsTile.svelte";

  let {
    away,
    onchange,
    onclose,
  }: {
    away: AwayInfo;
    onchange: (info: CompanionInfo) => void;
    onclose: () => void;
  } = $props();

  let token = $state("");
  let manualAddress = $state("");
  let started = $state(false);
  let submitError = $state<string | null>(null);

  const cleanToken = $derived(token.trim());
  const settingUp = $derived(away.relaySetup.state === "working");
  const validManual = $derived(normalizeRelayUrl(manualAddress) !== null);
  const checkState = $derived(
    submitError
      ? ({ kind: "failed", message: submitError } as const)
      : ownRelayCheckState(started || settingUp, away.relaySetup, away.relay.address, away.relayStatus),
  );

  async function openCloudflare() {
    try {
      const url = await companion.cloudflareTokenUrl();
      await openUrl(url);
    } catch {
      // Fallback if command is unavailable in preview mode.
    }
  }

  async function setUp() {
    if (!cleanToken || settingUp) return;
    started = true;
    submitError = null;
    const value = cleanToken;
    token = "";
    try {
      onchange(await companion.setupOwnRelay(value));
    } catch (e) {
      submitError = tr("Instellen is niet gelukt: {message}", "Setting up did not work: {message}", {
        message: String(e),
      });
    }
  }

  async function useManualAddress() {
    const normalized = normalizeRelayUrl(manualAddress);
    if (!normalized) return;
    started = true;
    submitError = null;
    try {
      onchange(await companion.setRelay(true, true, normalized));
      manualAddress = "";
    } catch (e) {
      submitError = String(e);
    }
  }
</script>

<SetupSheet
  title={tr("Je eigen relay", "Your own relay")}
  subtitle={tr(
    "Je eigen relay draait op een gratis Cloudflare-account. Nook zet hem daar voor je op met één Cloudflare-sleutel.",
    "Your own relay runs on a free Cloudflare account. Nook puts it there for you with one Cloudflare token.",
  )}
  {onclose}
>
  {#snippet icon()}
    <SettingsTile icon="globe" size={40} />
  {/snippet}

  <SetupStep number={1} title={tr("Maak een sleutel bij Cloudflare", "Make a token at Cloudflare")}>
    <StepAction
      detail={tr(
        "Log in (of maak een gratis account) en maak de sleutel die al voor je is ingevuld, of kies de sjabloon “Edit Cloudflare Workers”.",
        "Sign in (or create a free account) and create the token that is filled in for you, or pick the template “Edit Cloudflare Workers”.",
      )}
      button={tr("Cloudflare openen", "Open Cloudflare")}
      prominent={false}
      onclick={openCloudflare}
    />
  </SetupStep>

  <SetupStep number={2} title={tr("Plak de sleutel", "Paste the token")} done={cleanToken.length > 0 || settingUp || checkState.kind === "passed"}>
    <input
      class="relay-input"
      type="password"
      bind:value={token}
      placeholder={tr("Plak de sleutel", "Paste the token")}
      aria-label={tr("Plak de sleutel", "Paste the token")}
      onkeydown={(e) => e.key === "Enter" && setUp()}
    />
  </SetupStep>

  <SetupCheckStep
    number={3}
    title={tr("Relay instellen", "Set up the relay")}
    detail={tr(
      "Nook zet de relay op je Cloudflare-account en controleert of deze computer ermee verbindt.",
      "Nook puts the relay on your Cloudflare account and checks that this computer connects to it.",
    )}
    state={checkState}
    buttonLabel={tr("Instellen", "Set up")}
    disabled={!cleanToken || settingUp}
    oncheck={setUp}
  />

  {#if away.relaySetup.state === "working"}
    <SettingNote text={deployStepText(away.relaySetup.step)} />
  {/if}

  <Fold title={tr("Ik heb al een relay", "I already have a relay")}>
    <div class="manual-box">
      <input
        class="relay-input"
        type="url"
        bind:value={manualAddress}
        placeholder="https://nook-relay.you.workers.dev"
        aria-label="https://nook-relay.you.workers.dev"
        onkeydown={(e) => e.key === "Enter" && useManualAddress()}
      />
      <button type="button" disabled={!validManual} onclick={useManualAddress}>
        {tr("Gebruiken", "Use")}
      </button>
    </div>
  </Fold>

  {#snippet footer()}
    <span class="foot-spacer"></span>
    <button type="button" class="primary" onclick={onclose}>
      {tr("Klaar", "Done")}
    </button>
  {/snippet}
</SetupSheet>

<style>
  .relay-input {
    width: 100%;
  }
  .manual-box {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-8);
    padding: var(--space-12);
  }
  .foot-spacer {
    flex: 1;
  }
</style>
