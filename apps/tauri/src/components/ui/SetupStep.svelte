<script lang="ts">
  // A numbered step inside a `SetupSheet`, mirroring Mac's `SetupStep` (`SettingsStyle.swift`):
  // 24px circular badge (`--iris` / `--on-iris`, flipping to `--mint` with a check mark once done),
  // strong step title (never carrying its own number), and the step's content underneath.
  import type { Snippet } from "svelte";
  import Ico from "./Ico.svelte";

  let {
    number,
    title,
    done = false,
    children,
  }: {
    number: number;
    title: string;
    done?: boolean;
    children?: Snippet;
  } = $props();
</script>

<div class="setup-step" class:done>
  <span class="step-badge" class:done aria-hidden="true">
    {#if done}
      <Ico name="check" size={12} stroke={2.8} />
    {:else}
      {number}
    {/if}
  </span>
  <div class="step-main">
    <div class="step-title">{title}</div>
    {#if children}
      <div class="step-content">
        {@render children()}
      </div>
    {/if}
  </div>
</div>

<style>
  .setup-step {
    display: flex;
    align-items: flex-start;
    gap: var(--space-16);
    width: 100%;
  }
  .step-badge {
    width: 24px;
    height: 24px;
    flex: none;
    display: grid;
    place-items: center;
    border-radius: 999px;
    background: var(--iris);
    color: var(--on-iris);
    font: var(--text-label);
    font-weight: 700;
  }
  .step-badge.done {
    background: var(--mint);
    color: var(--ink);
  }
  .step-main {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
  }
  .step-title {
    font: var(--text-emphasis);
    color: var(--paper);
    padding-top: var(--space-2);
  }
  .step-content {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-8);
    min-width: 0;
  }
</style>
