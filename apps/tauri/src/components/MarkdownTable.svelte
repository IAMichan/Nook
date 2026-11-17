<script lang="ts">
  // A Markdown table (`TableBlock` & `TableCopyMenu` on the Mac): numeric columns right-aligned with tabular digits,
  // horizontal scroll when wide, and a Copy menu under it to copy as Markdown or CSV.
  import { tr } from "../lib/i18n.svelte";
  import {
    isNumericColumn,
    renderInlineMarkdown,
    tableToCsv,
    tableToMarkdown,
    type InlineOptions,
  } from "../lib/markdown-blocks";
  import Icon from "./Icon.svelte";

  let {
    header,
    rows,
    citation,
  }: {
    header: string[];
    rows: string[][];
    citation?: InlineOptions["citation"];
  } = $props();

  let menuOpen = $state(false);
  let copied = $state(false);
  let wrapEl: HTMLDivElement;

  const numeric = $derived(header.map((_, col) => isNumericColumn(rows, col)));
  const inlineOpts = $derived(citation ? { citation } : {});

  async function copyAs(kind: "markdown" | "csv") {
    menuOpen = false;
    const text = kind === "markdown" ? tableToMarkdown(header, rows) : tableToCsv(header, rows);
    try {
      await navigator.clipboard?.writeText(text);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      // Clipboard may be unavailable.
    }
  }

  function handleWindowClick(e: MouseEvent) {
    if (!menuOpen) return;
    if (wrapEl && !wrapEl.contains(e.target as Node)) menuOpen = false;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (menuOpen && e.key === "Escape") menuOpen = false;
  }
</script>

<svelte:window onclick={handleWindowClick} onkeydown={handleKeydown} />

<div class="table-block" bind:this={wrapEl}>
  <div class="table-scroll">
    <table>
      <thead>
        <tr>
          {#each header as cell, col (col)}
            <th class:num={numeric[col]}>{@html renderInlineMarkdown(cell, inlineOpts)}</th>
          {/each}
        </tr>
      </thead>
      <tbody>
        {#each rows as row, rowIdx (rowIdx)}
          <tr>
            {#each row as cell, col (col)}
              <td class:first={col === 0} class:num={numeric[col]}>{@html renderInlineMarkdown(cell, inlineOpts)}</td>
            {/each}
          </tr>
        {/each}
      </tbody>
    </table>
  </div>

  <div class="table-foot">
    <div class="menu-wrap">
      <button
        type="button"
        class="copy-menu-btn"
        class:copied
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        title={copied ? tr("Gekopieerd", "Copied") : tr("Tabel kopiëren", "Copy table")}
        aria-label={tr("Tabel kopiëren", "Copy table")}
        onclick={() => (menuOpen = !menuOpen)}
      >
        <Icon name={copied ? "check" : "copy"} size={12} />
      </button>
      {#if menuOpen}
        <div class="copy-menu" role="menu">
          <button type="button" role="menuitem" onclick={() => copyAs("markdown")}>
            {tr("Kopiëren als Markdown", "Copy as Markdown")}
          </button>
          <button type="button" role="menuitem" onclick={() => copyAs("csv")}>
            {tr("Kopiëren als CSV", "Copy as CSV")}
          </button>
        </div>
      {/if}
    </div>
  </div>
</div>

<style>
  .table-block {
    margin: 6px 0 10px;
  }
  .table-scroll {
    overflow-x: auto;
  }
  .table-block table {
    width: 100%;
    border-collapse: collapse;
    margin: 0;
  }
  .table-block th, .table-block td {
    border: none;
    border-bottom: 1px solid var(--line);
    padding: 8px 14px 8px 0;
    text-align: left;
    vertical-align: top;
  }
  .table-block th:last-child, .table-block td:last-child {
    padding-right: 0;
  }
  .table-block th {
    color: var(--paper);
    font-weight: 600;
    border-bottom-color: var(--line2);
  }
  .table-block td {
    color: var(--text-strong);
    font-variant-numeric: tabular-nums;
  }
  .table-block td.first {
    font-weight: 500;
  }
  .table-block th.num, .table-block td.num {
    text-align: right;
  }
  .table-foot {
    display: flex;
    justify-content: flex-end;
    margin-top: 2px;
  }
  .menu-wrap {
    position: relative;
  }
  .copy-menu-btn {
    display: inline-grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: var(--text3);
  }
  .copy-menu-btn:hover {
    background: var(--row-hover);
    color: var(--paper);
  }
  .copy-menu-btn.copied {
    color: var(--mint);
  }
  .copy-menu {
    position: absolute;
    right: 0;
    top: calc(100% + 4px);
    z-index: 30;
    min-width: 170px;
    padding: 4px;
    background: var(--menu);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    box-shadow: var(--shadow-popover);
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .copy-menu button {
    border: none;
    background: transparent;
    text-align: left;
    font-size: 12px;
    font-weight: 400;
    padding: 6px 10px;
    border-radius: 6px;
    color: var(--paper);
    white-space: nowrap;
  }
  .copy-menu button:hover {
    background: var(--row-hover);
  }
</style>
