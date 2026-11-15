<script lang="ts">
  // A session's changes, as the iPhone's "Changes" (`SessionChangesView`): every file it changed in its folder, the most
  // changed first, with its patch. Pick lines and Comment: the comment goes into the session's message as the Mac's
  // review sends it (`<review_comment>`).
  import { onMount } from "svelte";
  import { companion, type ClientView, type DiffFile } from "../../lib/companion";
  import { reviewComment, newNumbers } from "../../lib/patch";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import NavBar from "./ui/NavBar.svelte";
  import FileCard from "./ui/FileCard.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Dialog from "./ui/Dialog.svelte";

  let { session, onback, oncomment, took }: { session: string; onback: () => void; oncomment: (block: string) => void; took: (v: ClientView) => void } = $props();
  let files = $state<DiffFile[] | null>(null);
  let asking = $state<{ path: string; lines: string[]; from: number; to: number; note: string } | null>(null);
  const added = $derived(files?.reduce((n, f) => n + (f.added ?? 0), 0) ?? 0);
  const removed = $derived(files?.reduce((n, f) => n + (f.removed ?? 0), 0) ?? 0);

  onMount(async () => {
    const r = await companion.call({ op: "diff", session });
    took(r.view);
    files = (r.response?.diff ?? []).sort((a, b) => (b.added ?? 0) + (b.removed ?? 0) - ((a.added ?? 0) + (a.removed ?? 0)));
  });
</script>

<div class="changes">
  <NavBar onback={onback}>{#snippet center()}<strong class="t">{tr("Wijzigingen", "Changes")}</strong>{/snippet}</NavBar>
  <div class="scroll">
    {#if files === null}
      <div class="spinner"></div>
    {:else if !files.length}
      <EmptyState icon="diff" title={tr("Geen wijzigingen", "No changes")} text={tr("De map van de sessie heeft geen wijzigingen ten opzichte van de laatste commit.", "The session's folder has no changes against its last commit.")} />
    {:else}
      <p class="totals">{files.length === 1 ? tr("1 bestand", "1 file") : tr("{n} bestanden", "{n} files", { n: files.length })} <span class="add">+{added}</span> <span class="del">−{removed}</span></p>
      {#each files as f (f.path)}
        <FileCard path={f.path} kind={f.kind} added={f.added} removed={f.removed} patch={f.patch} truncated={f.truncated}
          oncomment={(from, to, lines) => (asking = { path: f.path, lines, from, to, note: "" })} />
      {/each}
    {/if}
  </div>
</div>

{#if asking}
  {@const a = asking}
  <Dialog title={tr("Opmerking voor de agent", "Comment for the agent")} message={tr("Het komt in je bericht aan de sessie, met de regels waar het over gaat.", "It goes into your message to the session, with the lines it is about.")}
    bind:field={a.note} placeholder={tr("Wat moet hier veranderen?", "What should change here?")} onclose={() => (asking = null)} buttons={[
      { label: tr("Toevoegen aan bericht", "Add to message"), bold: true, onselect: () => { if (a.note.trim()) { haptic("success"); oncomment(reviewComment(a.path, a.lines, newNumbers(a.lines), a.from, a.to, a.note.trim())); } } },
      { label: tr("Annuleer", "Cancel"), onselect: () => {} },
    ]} />
{/if}

<style>
  .changes { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .t { font: var(--pt-strong); }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 8px; }
  .totals { margin: 0; padding: 4px; font: var(--pt-label); color: var(--text2); }
  .add { color: var(--mint); font: var(--pt-code); font-size: 13px; }
  .del { color: var(--coral); font: var(--pt-code); font-size: 13px; }
  .spinner { margin: 60px auto; width: 26px; height: 26px; border-radius: 50%; border: 3px solid var(--smoke); border-top-color: var(--text2); animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
