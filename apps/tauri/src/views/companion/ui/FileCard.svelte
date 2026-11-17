<script lang="ts">
  // A changed file as a card (the iPhone's review screen): name, folder, kind and counts; open for its patch.
  import type { Snippet } from "svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  import PatchView from "./PatchView.svelte";
  let { path, kind, added, removed, patch, truncated, oncomment, extra, open = $bindable(false) }: {
    path: string; kind?: string; added?: number; removed?: number; patch?: string; truncated?: boolean;
    oncomment?: (from: number, to: number, lines: string[]) => void; extra?: Snippet; open?: boolean;
  } = $props();
  const name = $derived(path.split("/").pop() ?? path);
  const folder = $derived(path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "");
</script>

<div class="card">
  <button class="head" onclick={() => (open = !open)}>
    <span class="chev" class:open><Ico name="chevron-right" size={11} stroke={3} /></span>
    <span class="names"><strong>{name}</strong>{#if folder}<small>{folder}</small>{/if}</span>
    {#if kind && kind !== "modified"}<small class="kind">{kind}</small>{/if}
    <span class="counts">{#if added}<span class="add">+{added}</span>{/if}{#if removed}<span class="del">−{removed}</span>{/if}</span>
  </button>
  {@render extra?.()}
  {#if open}
    {#if patch}<PatchView {patch} {oncomment} />{:else}<p class="note">{tr("Geen patch om te tonen voor dit bestand.", "No patch to show for this file.")}</p>{/if}
    {#if truncated}<p class="note">{tr("De rest van de wijzigingen in dit bestand staat op je Mac.", "The rest of this file's changes is on your Mac.")}</p>{/if}
  {/if}
</div>

<style>
  .card { background: var(--surface); border: 1px solid var(--line2); border-radius: 10px; overflow: hidden; }
  .head { width: 100%; display: flex; align-items: center; gap: 8px; padding: 12px; text-align: left; }
  .chev { color: var(--text3); display: inline-flex; transition: transform var(--reveal); }
  .chev.open { transform: rotate(90deg); }
  .names { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  strong { font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  small { font: var(--pt-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .counts { display: flex; gap: 6px; font: var(--pt-code); font-size: 13px; font-variant-numeric: tabular-nums; }
  .add { color: var(--mint); }
  .del { color: var(--coral); }
  .note { margin: 0; padding: 8px 12px; font: var(--pt-detail); color: var(--text3); }
</style>
