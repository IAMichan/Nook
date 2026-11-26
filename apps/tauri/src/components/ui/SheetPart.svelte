<script lang="ts">
  // One grouped part of a linked connection sheet ("Account", "Keys & security", "In Nook",
  // "What Nook can do with it"), mirroring Mac's `SheetPart` (`SettingsStyle.swift`).
  import type { Snippet } from "svelte";

  let {
    title,
    embedded = false,
    children,
  }: {
    title: string;
    embedded?: boolean;
    children: Snippet;
  } = $props();
</script>

<section class="sheet-part">
  <h4 class="part-title">{title}</h4>
  <div class="part-card" class:embedded>
    {@render children()}
  </div>
</section>

<style>
  .sheet-part {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    width: 100%;
  }
  .part-title {
    margin: 0;
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .part-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    padding: var(--space-16);
    border-radius: var(--radius-card);
    background: var(--surface);
    border: 1px solid var(--separator);
  }
  .part-card.embedded {
    padding: 0;
    background: transparent;
    border: none;
    border-radius: 0;
  }
</style>
