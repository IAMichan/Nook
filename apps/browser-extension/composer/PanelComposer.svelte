<script>
  // The side panel's composer: Nook's shared composer (packages/web-ui, the same one the Tauri app uses) in the
  // panel's look, with its texts from the extension's _locales and "New chat" among its choices. Pictures only: the
  // panel has no way to read a document. `main.svelte.js` mounts it and passes the panel's state in `panel`.
  import Composer from '@nook/web-ui/Composer.svelte';
  import { Draft } from '@nook/web-ui/draft.svelte';

  let { panel, onsend, onstop, onnewchat } = $props();

  const t = (key) => globalThis.chrome?.i18n?.getMessage(key) || key;
  const draft = new Draft();
  let composer = $state();

  export function focus() {
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
      {#if panel.showNewChat}
        <button id="new-chat" type="button" class="quiet small" onclick={onnewchat}>{t('newChat')}</button>
      {/if}
    {/snippet}
  </Composer>
</div>

<style>
  /* The shared composer in the panel's tokens (sidepanel.css), which follow the look Nook sends. */
  .panel-composer {
    --nc-surface: var(--composer-tray);
    --nc-surface-focus: var(--composer);
    --nc-line: var(--field-stroke);
    --nc-line-focus: var(--line2);
    --nc-radius: var(--radius-composer);
    --nc-control-radius: var(--radius-control);
    --nc-pad: var(--space-md) var(--space-md) var(--space-md) var(--space-lg);
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
