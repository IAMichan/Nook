<script lang="ts">
  // Settings › Accounts & connections › Chat apps, for someone coming from Beeper (`BeeperImportSection` and
  // `BeeperImportSheet` on the Mac, CH-20): one row that opens the move in a sheet — pasting Beeper Desktop's
  // local token, bringing over what Beeper Desktop has in one click, and linking each app that was linked there.
  import {
    beeperAppDetail,
    beeperAppMeta,
    beeperCheckState,
    beeperImportApi,
    beeperProblemText,
    beeperSummaryText,
    type BeeperImportStatus,
  } from "../../lib/beeper-import";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import Dialog from "../../components/ui/Dialog.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import Spinner from "../../components/ui/Spinner.svelte";
  import StepAction from "../../components/ui/StepAction.svelte";
  import ConnectionRow from "../settings/ConnectionRow.svelte";
  import SettingNote from "../settings/SettingNote.svelte";
  import SettingsLinkRow from "../settings/SettingsLinkRow.svelte";
  import SettingsSection from "../settings/SettingsSection.svelte";
  import ServiceIcon from "./ServiceIcon.svelte";

  let {
    isChatLinked,
    onOpenChatApp,
  }: {
    isChatLinked: (app: string) => boolean;
    onOpenChatApp: (app: string) => void;
  } = $props();

  let status = $state<BeeperImportStatus | null>(null);
  let open = $state(false);
  let token = $state("");
  let savingToken = $state(false);
  let running = $state(false);
  let confirmFinish = $state(false);

  async function load() {
    try {
      status = await beeperImportApi.status();
    } catch {
      status = null;
    }
  }

  $effect(() => {
    load();
  });

  const busy = $derived(running || !!status?.busy);
  const apps = $derived(status?.apps ?? []);
  const allAppsLinked = $derived(apps.length > 0 && apps.every((app) => isChatLinked(app)));
  const checkState = $derived(
    status
      ? beeperCheckState({ imported: status.imported, busy, apps: status.apps }, isChatLinked)
      : ({ kind: "idle" } as const),
  );

  async function saveToken() {
    const trimmed = token.trim();
    if (!trimmed || savingToken) return;
    savingToken = true;
    try {
      status = await beeperImportApi.saveToken(trimmed);
      token = "";
    } catch {
      toast.error(tr("Beepers token kon niet worden bewaard", "Could not save Beeper's token"));
    } finally {
      savingToken = false;
    }
  }

  async function runImport() {
    if (busy) return;
    running = true;
    try {
      status = await beeperImportApi.run();
    } catch {
      await load();
    } finally {
      running = false;
    }
  }

  async function finishMove() {
    try {
      status = await beeperImportApi.finish();
    } catch {
      await load();
    }
    confirmFinish = false;
    open = false;
  }

  function openBeeper() {
    beeperImportApi.openApp().catch(() => {});
  }

  function linkApp(app: string) {
    open = false;
    onOpenChatApp(app);
  }
</script>

{#if status?.offered}
  <SettingsSection
    title={tr("Overstappen van Beeper", "Moving from Beeper")}
    info={tr(
      "Een inlog zelf kan niet mee: Beeper bewaart die en geeft ze niet af, dus elke app koppel je nog één keer in Nook. Nook leest Beeper alleen op deze computer, en alleen als je op Importeer klikt.",
      "A sign-in itself cannot come over: Beeper keeps those and does not hand them out, so each app is linked once more in Nook. Nook reads Beeper only on this computer, and only when you click Import.",
    )}
  >
    <SettingsLinkRow
      title={tr("Neem je Beeper-instellingen mee", "Bring your Beeper setup over")}
      detail={status.imported === null
        ? tr(
            "Neem mee welke apps gekoppeld zijn, je chats en hun geschiedenis.",
            "Bring over which apps are linked, your chats and their history.",
          )
        : tr(
            "Geïmporteerd. Open het om de apps te koppelen die in Beeper gekoppeld waren.",
            "Imported. Open it to link the apps that were linked in Beeper.",
          )}
      onclick={() => (open = true)}
    />
  </SettingsSection>
{/if}

{#if open && status}
  <SetupSheet
    title={tr("Neem je Beeper-instellingen mee", "Bring your Beeper setup over")}
    subtitle={tr(
      "Nook koppelt je chat-apps nu zelf, zonder Beeper. Eén klik haalt op wat Beeper Desktop heeft: welke apps gekoppeld zijn en als wie, je chats met hun recente geschiedenis, en welke chats vastgezet, gedempt of gearchiveerd zijn.",
      "Nook links your chat apps itself now, without Beeper. One click brings over what Beeper Desktop has: which apps are linked and as whom, your chats with their recent history, and which chats are pinned, muted or archived.",
    )}
    onclose={() => (open = false)}
  >
    {#snippet icon()}
      <ServiceIcon domain="beeper.com" title="Beeper" size={48} />
    {/snippet}

    <SetupStep number={1} title={tr("Beeper-toegangstoken", "Beeper access token")} done={status.hasToken}>
      {#if !status.hasToken}
        <StepAction
          detail={tr(
            "Zet in Beeper Desktop › Instellingen › Developers de Desktop API aan, maak een token en plak het hier. Beeper moet open zijn.",
            "In Beeper Desktop › Settings › Developers, turn on the Desktop API, create a token and paste it here. Beeper has to be open.",
          )}
          button={tr("Open Beeper", "Open Beeper")}
          prominent={false}
          onclick={openBeeper}
        />
        <input
          class="token-input"
          type="password"
          bind:value={token}
          placeholder={tr("Beeper-toegangstoken", "Beeper access token")}
          aria-label={tr("Beeper-toegangstoken", "Beeper access token")}
          onkeydown={(e) => e.key === "Enter" && saveToken()}
        />
        <button type="button" class="primary" disabled={!token.trim() || savingToken} onclick={saveToken}>
          {tr("Bewaar", "Save")}
        </button>
      {/if}
    </SetupStep>

    <SetupStep number={2} title={tr("Importeer uit Beeper", "Import from Beeper")} done={status.imported !== null}>
      {#if status.hasToken}
        <StepAction
          detail={tr(
            "Beeper Desktop moet open zijn. Er gaat niets van deze computer af.",
            "Beeper Desktop has to be open. Nothing leaves this computer.",
          )}
          button={status.imported === null ? tr("Importeer", "Import") : tr("Opnieuw importeren", "Import again")}
          prominent={status.imported === null}
          disabled={busy}
          onclick={runImport}
        />
        {#if busy}
          <Spinner size={14} />
        {/if}
      {/if}
      {#if status.problem}
        <SettingNote text={beeperProblemText(status.problem)} tone="warning" />
      {/if}
      {#if status.imported}
        <SettingNote
          text={`${tr("Geïmporteerd", "Imported")} ${beeperSummaryText(status.imported)}`}
          tone="success"
        />
      {/if}
    </SetupStep>

    {#if apps.length > 0}
      <SetupStep number={3} title={tr("Gekoppeld in Beeper", "Linked in Beeper")} done={allAppsLinked}>
        <div class="apps-list">
          {#each apps as app (app)}
            {@const meta = beeperAppMeta(app)}
            {@const linked = isChatLinked(app)}
            <ConnectionRow
              title={meta.name}
              status={beeperAppDetail(app, status.accounts, linked)}
              menu={linked ? [] : [{ label: tr("Koppel", "Link"), onselect: () => linkApp(app) }]}
            >
              {#snippet icon()}
                <ServiceIcon domain={meta.domain} title={meta.name} size={28} />
              {/snippet}
            </ConnectionRow>
          {/each}
        </div>
      </SetupStep>
    {/if}

    <SetupCheckStep
      number={apps.length === 0 ? 3 : 4}
      title={tr("Controleer wat er meekwam", "Check what came over")}
      detail={tr(
        "Na het importeren zegt Nook welke apps uit Beeper hier gekoppeld zijn.",
        "After the import, Nook says which of Beeper's apps are linked here.",
      )}
      state={checkState}
    />

    {#snippet footer()}
      <button type="button" disabled={busy} onclick={() => (confirmFinish = true)}>
        {tr("Klaar met overstappen", "Done moving")}
      </button>
      <span class="foot-spacer"></span>
      <button type="button" class="primary" onclick={() => (open = false)}>
        {tr("Klaar", "Done")}
      </button>
    {/snippet}
  </SetupSheet>
{/if}

{#if confirmFinish}
  <Dialog
    title={tr("Klaar met overstappen", "Done moving")}
    message={tr(
      "Nook vergeet Beepers token en biedt dit niet meer aan. Wat nog op een app wacht, volgt als je die later koppelt.",
      "Nook forgets Beeper's token and stops offering this. Anything still waiting for an app follows when you link it later.",
    )}
    buttons={[
      { label: tr("Klaar", "Done"), bold: true, onselect: finishMove },
      { label: tr("Annuleer", "Cancel"), onselect: () => (confirmFinish = false) },
    ]}
    onclose={() => (confirmFinish = false)}
  />
{/if}

<style>
  .token-input {
    width: 100%;
  }
  .apps-list {
    width: 100%;
    display: flex;
    flex-direction: column;
  }
  .foot-spacer {
    flex: 1;
  }
</style>
