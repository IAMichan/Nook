<script lang="ts">
  // Publish a local project to GitHub (`PublishRepositorySheet.swift` on macOS, AG-120):
  // Step 1: Repository name (validated against GitHub's rules).
  // Step 2: Optional owner/organization + Private repository toggle (default on).
  // Step 3: Exact list of steps Nook will run; nothing runs until you click Publish.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import Ico from "../../components/ui/Ico.svelte";
  import SetupCheckStep from "../../components/ui/SetupCheckStep.svelte";
  import SetupSheet from "../../components/ui/SetupSheet.svelte";
  import SetupStep from "../../components/ui/SetupStep.svelte";
  import type { SetupCheckState } from "../../components/ui/setup-check";
  import SettingNote from "./SettingNote.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { workspaceApi, type PublishPlan } from "../../lib/workspace/api";
  import { isValidRepositoryName } from "../../lib/workspace/source-control";

  let {
    plan,
    ondone,
  }: {
    plan: PublishPlan;
    ondone: (url: string | null) => void;
  } = $props();

  let name = $state(plan.name);
  let owner = $state("");
  let isPrivate = $state(true);
  let working = $state(false);
  let error = $state<string | null>(null);

  const valid = $derived(isValidRepositoryName(name));

  const steps = $derived.by(() => {
    const list: string[] = [];
    if (plan.needsRepository) {
      list.push(tr("• Git-repository aanmaken in deze map (git init)", "• Initialize a Git repository in this folder (git init)"));
    }
    if (plan.needsFirstCommit) {
      list.push(tr("• Alle bestanden in een eerste commit vastleggen", "• Commit all files into an initial commit"));
    }
    const cleanOwner = owner.trim();
    const target = `${cleanOwner || tr("jouw account", "your account")}/${name || plan.name}`;
    list.push(
      isPrivate
        ? tr("• Privé-repository aanmaken op GitHub: {target}", "• Create private repository on GitHub: {target}", { target })
        : tr("• Openbare repository aanmaken op GitHub: {target}", "• Create public repository on GitHub: {target}", { target }),
    );
    list.push(tr("• Remote origin instellen en de huidige branch pushen", "• Set remote origin and push the current branch"));
    return list;
  });

  const summary = $derived(`${tr("Dit gaat Nook doen", "What Nook will do")}:\n${steps.join("\n")}`);

  const checkState = $derived.by<SetupCheckState>(() => {
    if (working) return { kind: "checking" };
    if (error) return { kind: "failed", message: error };
    return { kind: "idle" };
  });

  async function publish() {
    if (working || !valid) return;
    working = true;
    error = null;
    try {
      const cleanOwner = owner.trim();
      const url = await workspaceApi.publishRepository(plan.folder, name, cleanOwner || null, isPrivate);
      toast.withAction(tr("Gepubliceerd op GitHub", "Published to GitHub"), {
        label: tr("Openen", "Open"),
        run: () => {
          openUrl(url).catch(() => {});
        },
      });
      ondone(url);
    } catch (e) {
      error = String(e);
    } finally {
      working = false;
    }
  }
</script>

<SetupSheet
  title={tr("Publiceren op GitHub", "Publish to GitHub")}
  subtitle={plan.folder}
  onclose={() => {
    if (!working) ondone(null);
  }}
>
  {#snippet icon()}
    <span class="publish-icon"><Ico name="upload" size={22} /></span>
  {/snippet}

  <SetupStep number={1} title={tr("Naam van de repository", "Repository name")} done={valid}>
    <input
      class="publish-input"
      type="text"
      bind:value={name}
      placeholder={plan.name}
      aria-label={tr("Naam van de repository", "Repository name")}
      disabled={working}
    />
    {#if !valid}
      <SettingNote
        tone="warning"
        text={tr(
          "Gebruik letters, cijfers, '.', '-' en '_', maximaal 100 tekens.",
          "Use letters, digits, '.', '-' and '_', at most 100 characters.",
        )}
      />
    {/if}
  </SetupStep>

  <SetupStep number={2} title={tr("Waar en zichtbaarheid", "Destination and visibility")} done={true}>
    <label class="field-label">
      <span>{tr("Eigenaar of organisatie (optioneel)", "Owner or organization (optional)")}</span>
      <input
        class="publish-input"
        type="text"
        bind:value={owner}
        placeholder={tr("Leeg voor je eigen GitHub-account", "Leave empty for your own GitHub account")}
        disabled={working}
      />
    </label>
    <label class="switch-row">
      <span>{tr("Privé-repository", "Private repository")}</span>
      <input type="checkbox" role="switch" bind:checked={isPrivate} disabled={working} />
    </label>
  </SetupStep>

  <SetupCheckStep
    number={3}
    title={tr("Klaar om te publiceren", "Ready to publish")}
    detail={summary}
    state={checkState}
    checkingLabel={tr("Publiceren op GitHub…", "Publishing to GitHub…")}
  />

  {#snippet footer()}
    <span class="spacer"></span>
    <button type="button" onclick={() => ondone(null)} disabled={working}>
      {tr("Annuleer", "Cancel")}
    </button>
    <button type="button" class="primary" onclick={publish} disabled={working || !valid}>
      {working ? tr("Publiceren…", "Publishing…") : tr("Publiceer", "Publish")}
    </button>
  {/snippet}
</SetupSheet>

<style>
  .publish-icon {
    color: var(--text2);
    display: grid;
    place-items: center;
  }
  .publish-input {
    width: 100%;
    max-width: 340px;
  }
  .field-label {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    width: 100%;
    font: var(--text-detail);
    color: var(--text2);
  }
  .switch-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
    width: 100%;
    max-width: 340px;
    font: var(--text-body);
    color: var(--paper);
  }
  .spacer {
    flex: 1;
  }
  :global(.setup-body .check-note) {
    white-space: pre-line;
  }
</style>
