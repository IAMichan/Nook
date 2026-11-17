<script lang="ts">
  // What the session menus ask first (the iPhone's `SessionPromptHost`): a new name, Delete (with the session's own
  // worktree where the computer offers it), and End.
  import { untrack } from "svelte";
  import type { SessionDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import Dialog from "./ui/Dialog.svelte";

  let { kind, session, onrun, onclose }: {
    kind: "rename" | "delete" | "end";
    session: SessionDigest;
    onrun: (action: string, text?: string) => void;
    onclose: () => void;
  } = $props();
  let name = $state(untrack(() => session.title));
  const withWorktree = $derived((session.actions ?? []).includes("deleteWithWorktree"));
</script>

{#if kind === "rename"}
  <Dialog title={tr("Hernoem", "Rename")} bind:field={name} placeholder={tr("Naam", "Name")} {onclose} buttons={[
    { label: tr("Bewaar", "Save"), bold: true, onselect: () => name.trim() && onrun("rename", name.trim()) },
    { label: tr("Annuleer", "Cancel"), onselect: () => {} },
  ]} />
{:else if kind === "delete"}
  <Dialog title={tr("Deze sessie verwijderen?", "Delete this session?")}
    message={tr("Het gesprek verdwijnt uit Nook. De map blijft; een worktree met wijzigingen die nooit zijn vastgelegd blijft ook.", "Its conversation is removed from Nook. The folder stays; a worktree with changes that were never committed stays too.")}
    {onclose} buttons={[
      { label: tr("Verwijder", "Delete"), destructive: true, onselect: () => onrun("delete") },
      ...(withWorktree ? [{ label: tr("Verwijder met worktree", "Delete with worktree"), destructive: true, onselect: () => onrun("deleteWithWorktree") }] : []),
      { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} },
    ]} />
{:else}
  <Dialog title={tr("Deze sessie beëindigen?", "End this session?")} message={tr("De agent bewaart het gesprek, dus je kunt het in Nook voortzetten.", "The agent saves its conversation, so you can continue it in Nook.")} {onclose} buttons={[
    { label: tr("Beëindig sessie", "End session"), destructive: true, onselect: () => onrun("end") },
    { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} },
  ]} />
{/if}
