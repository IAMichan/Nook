<script>
  // The side panel's conversation: Nook's shared transcript (packages/web-ui), drawn as Nook's own window draws Nook
  // Chat, in the panel's tokens and with its texts from the extension's _locales.
  import Transcript from '@nook/web-ui/Transcript.svelte';

  let { panel } = $props();

  const t = (key) => globalThis.chrome?.i18n?.getMessage(key) || key;
  const texts = {
    thinking: t('thinking'),
    onMac: t('onMacNote'),
    copy: t('copy'),
    copyTitle: t('copyCode'),
    copied: t('copied')
  };
</script>

<div class="panel-transcript">
  <Transcript messages={panel.messages} {texts} />
</div>

<style>
  .panel-transcript {
    --nt-text: var(--text-strong);
    --nt-faint: var(--text-tertiary);
    --nt-line: var(--line2);
    --nt-card: var(--surface);
    --nt-card-radius: var(--radius-card);
    --nt-bubble: var(--bubble);
    --nt-bubble-radius: var(--radius-bubble);
    --nt-code: var(--graphite);
    --nt-hover: var(--row-hover);
    --nt-accent: var(--blue);
    --nt-on-accent: var(--canvas);
    --nt-ok: var(--mint);
    --nt-warn: var(--amber);
    --nt-error: var(--coral);
    --nt-mono: var(--mono);
    font: var(--body)/1.55 var(--sans);
  }
</style>
