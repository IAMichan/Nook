<script lang="ts">
  // What one step of a setup flow asks the user to do, mirroring Mac's `StepAction` (`SettingsStyle.swift`):
  // optional strong heading, one line of explanation, and the action button underneath (never beside a label).
  let {
    title,
    detail,
    button,
    prominent = true,
    disabled = false,
    onclick,
  }: {
    title?: string;
    detail: string;
    button: string;
    prominent?: boolean;
    disabled?: boolean;
    onclick: () => void;
  } = $props();
</script>

<div class="step-action">
  {#if title}
    <div class="action-title">{title}</div>
  {/if}
  <p class="action-detail">{detail}</p>
  <button type="button" class:primary={prominent} {disabled} {onclick}>
    {button}
  </button>
</div>

<style>
  .step-action {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-8);
    width: 100%;
  }
  .action-title {
    font: var(--text-emphasis);
    color: var(--paper);
  }
  .action-detail {
    margin: 0;
    font: var(--text-detail);
    line-height: 1.4;
    color: var(--text2);
  }
</style>
