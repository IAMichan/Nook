<script lang="ts">
  // The final step of every setup flow, mirroring Mac's `SetupCheckStep` (`SettingsStyle.swift`):
  // Nook checks the link, key, address or command before it is saved, or says it is ready when nothing needs a check.
  import { tr } from "../../lib/i18n.svelte";
  import SetupStep from "./SetupStep.svelte";
  import Spinner from "./Spinner.svelte";
  import StepAction from "./StepAction.svelte";
  import { isSetupCheckPassed, type SetupCheckState } from "./setup-check";

  let {
    number,
    title,
    detail,
    state,
    oncheck,
    disabled = false,
    checkingLabel,
    buttonLabel,
    retryLabel,
  }: {
    number: number;
    title?: string;
    detail: string;
    state: SetupCheckState;
    oncheck?: () => void;
    disabled?: boolean;
    checkingLabel?: string;
    buttonLabel?: string;
    retryLabel?: string;
  } = $props();

  const resolvedTitle = $derived(title ?? tr("Verbinding controleren", "Check the connection"));
  const resolvedChecking = $derived(checkingLabel ?? tr("Controleren…", "Checking…"));
  const resolvedButton = $derived(buttonLabel ?? tr("Controleer", "Check"));
  const resolvedRetry = $derived(retryLabel ?? tr("Opnieuw proberen", "Try again"));
</script>

<SetupStep {number} title={resolvedTitle} done={isSetupCheckPassed(state)}>
  {#if state.kind === "idle"}
    {#if oncheck}
      <StepAction {detail} button={resolvedButton} prominent={false} {disabled} onclick={oncheck} />
    {:else}
      <p class="check-note">{detail}</p>
    {/if}
  {:else if state.kind === "checking"}
    <div class="check-busy">
      <Spinner size={12} />
      <span>{resolvedChecking}</span>
    </div>
  {:else if state.kind === "passed"}
    <p class="check-note ok">{state.message}</p>
  {:else}
    <p class="check-note err">{state.message}</p>
    {#if oncheck}
      <button type="button" {disabled} onclick={oncheck}>{resolvedRetry}</button>
    {/if}
  {/if}
</SetupStep>

<style>
  .check-note {
    margin: 0;
    font: var(--text-detail);
    line-height: 1.4;
    color: var(--text2);
  }
  .check-note.ok {
    color: var(--mint);
  }
  .check-note.err {
    color: var(--coral);
  }
  .check-busy {
    display: flex;
    align-items: flex-start;
    gap: var(--space-8);
    font: var(--text-detail);
    line-height: 1.4;
    color: var(--text2);
  }
</style>
