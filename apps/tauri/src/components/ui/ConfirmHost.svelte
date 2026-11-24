<script lang="ts">
  // The front question of `ask()` (`lib/confirm.svelte.ts`) in the shared `Dialog`: the confirm button first (on the
  // right), Cancel last and bold, so Return never removes anything by accident.
  import { confirmations } from "../../lib/confirm.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Dialog from "./Dialog.svelte";
  const front = $derived(confirmations.front);
  let remembered = $state(false);
</script>

{#if front}
  {#key front.id}
    <Dialog title={front.question} message={front.detail} remember={front.dontAskAgain} bind:remembered onclose={() => front.answer(false)} buttons={[
      { label: front.confirmTitle, destructive: front.destructive !== false, bold: front.destructive === false, onselect: () => { if (remembered) front.onRemember?.(); front.answer(true); } },
      { label: tr("Annuleer", "Cancel"), bold: front.destructive !== false, onselect: () => front.answer(false) },
    ]} />
  {/key}
{/if}
