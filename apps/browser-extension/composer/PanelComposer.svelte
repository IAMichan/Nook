<script>
  // The side panel's composer: Nook's shared composer (packages/web-ui, the same one the Tauri app uses) in the
  // panel's look, with its texts from the extension's _locales and, in its row, the model chip as in Nook's own
  // composer on the Mac (`BrainChip`). Pictures only: the panel has no way to read a document. `main.svelte.js` mounts
  // it and passes the panel's state in `panel`.
  import Composer from '@nook/web-ui/Composer.svelte';
  import ModelPicker from '@nook/web-ui/ModelPicker.svelte';
  import { Draft } from '@nook/web-ui/draft.svelte';

  let { panel, onsend, onstop, onbrain, onchoosebrain } = $props();

  const t = (key) => globalThis.chrome?.i18n?.getMessage(key) || key;
  const draft = new Draft();
  let composer = $state();

  export function focus() {
    composer?.focus();
  }

  /** Puts a question in the field (a suggestion), ready to send or change. */
  export function fill(text) {
    draft.text = text;
    composer?.focus();
  }

  const texts = {
    placeholder: t('askPlaceholder'),
    field: t('messageField'),
    send: t('send'),
    stop: t('stopAnswer'),
    attach: t('attachImages'),
    removeImage: t('removeImage')
  };

  const modelTexts = { button: t('modelChip'), search: t('modelSearch'), empty: t('modelEmpty') };

  function send({ text, images }) {
    onsend(text || t('imageQuestion'), images);
  }
</script>

<div class="panel-composer">
  <Composer
    bind:this={composer}
    {draft}
    {texts}
    busy={panel.busy}
    disabled={!panel.connected}
    history={panel.history}
    historyKey={panel.conversation}
    escapeStops={true}
    onsend={send}
    onstop={panel.canStop ? onstop : undefined}
  >
    {#snippet controls()}
      {#if panel.brain}
        <ModelPicker
          label={panel.brain.label}
          group={panel.brain.group}
          choices={panel.brain.choices}
          texts={modelTexts}
          disabled={!panel.connected}
          onopen={onbrain}
          onchoose={onchoosebrain}
        />
      {/if}
    {/snippet}
  </Composer>
</div>

<style>
  /* The shared composer in the panel's tokens (sidepanel.css), which follow the look Nook sends. */
  .panel-composer {
    --nc-surface: var(--composer);
    --nc-surface-focus: var(--composer);
    --nc-line: var(--field-stroke);
    --nc-line-focus: var(--line2);
    --nc-radius: var(--radius-composer);
    --nc-control-radius: var(--radius-control);
    --nc-chip-radius: var(--radius-chip);
    --nc-menu: var(--surface);
    --nc-menu-radius: var(--radius-panel);
    --nc-pad: var(--space-md) var(--space-md) var(--space-md) var(--space-lg);
    --nc-shadow: 0 1px 0 color-mix(in srgb, var(--paper) 4%, transparent), 0 8px 24px rgb(0 0 0 / 0.12);
    --nc-text: var(--paper);
    --nc-faint: var(--text-tertiary);
    --nc-hover: var(--row-hover);
    --nc-accent: var(--accent);
    --nc-on-accent: var(--on-accent);
    --nc-accent-hover: var(--accent-hover);
    --nc-disabled: var(--smoke);
    --nc-stop: var(--paper);
    --nc-on-stop: var(--canvas);
    --nc-error: var(--coral);
    font: var(--body)/1.45 var(--sans);
  }
</style>
