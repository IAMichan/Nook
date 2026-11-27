<script>
  // The side panel's composer: Nook's shared composer (packages/web-ui, the same one the Tauri app uses) in the
  // panel's look, with its texts from the extension's _locales and, in its row, the model chip as in Nook's own
  // composer on the Mac (`BrainChip`). Under its models, the access on the site in front, as the Mac's model picker holds
  // the agent's access (`ModelPickerOptions`): ask before each step, or act without asking. Pictures only: the panel has
  // no way to read a document. `main.svelte.js` mounts it and passes the panel's state in `panel`.
  import Composer from '@nook/web-ui/Composer.svelte';
  import ModelPicker from '@nook/web-ui/ModelPicker.svelte';
  import { Draft } from '@nook/web-ui/draft.svelte';

  let { panel, onsend, onstop, onbrain, onchoosebrain, onaccess } = $props();

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

  /** The two access levels on a site: the symbol (as the Mac's `PermissionPolicy.symbol`), name and what it allows. */
  const levels = [
    { trusted: false, icon: 'lock', label: t('accessAsk'), help: t('trustOff') },
    { trusted: true, icon: 'shield', label: t('accessTrust'), help: t('trustOn') }
  ];
  /** The level under the pointer, else the chosen one: its name and help show under the choice. */
  let hovered = $state(null);
  const shown = $derived(levels.find((level) => level.trusted === (hovered ?? panel.access?.trusted)) ?? levels[0]);

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
        >
          {#snippet footer()}
            {#if panel.access}
              <div class="access">
                <div class="access-title">{t('accessTitle').replace('$1', panel.access.site)}</div>
                <div class="access-levels" role="radiogroup" aria-label={t('accessTitle').replace('$1', panel.access.site)}>
                  {#each levels as level (level.trusted)}
                    <button type="button" role="radio" class:on={panel.access.trusted === level.trusted}
                            aria-checked={panel.access.trusted === level.trusted} title={level.label}
                            onmouseenter={() => (hovered = level.trusted)} onmouseleave={() => (hovered = null)}
                            onclick={() => panel.access.trusted !== level.trusted && onaccess(level.trusted)}>
                      <svg viewBox="0 0 16 16" aria-hidden="true">
                        {#if level.icon === 'lock'}
                          <rect x="3.5" y="7" width="9" height="6.5" rx="1.5" /><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" />
                        {:else}
                          <path d="M8 1.8 13 3.6v4c0 3-2.1 5.3-5 6.6-2.9-1.3-5-3.6-5-6.6v-4Z" /><path d="m5.8 8 1.6 1.6 2.9-3" />
                        {/if}
                      </svg>
                      <span>{level.label}</span>
                    </button>
                  {/each}
                </div>
                <p class="access-help">{shown.help}</p>
              </div>
            {/if}
          {/snippet}
        </ModelPicker>
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

  /* The access under the models: as the Mac's access panel, the levels side by side in a well, the one in use filled,
     and under them what the one shown allows. */
  .access { display: flex; flex-direction: column; gap: var(--space-sm); padding: var(--space-md); }
  .access-title { color: var(--text-tertiary); font-size: var(--label); font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .access-levels { display: flex; gap: 2px; padding: 2px; border-radius: var(--radius-control); background: var(--smoke); }
  .access-levels button {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-sm);
    min-width: 0;
    height: 28px;
    margin: 0;
    padding: 0 var(--space-md);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--detail);
    cursor: pointer;
  }
  .access-levels button.on { background: color-mix(in srgb, var(--paper) 12%, transparent); color: var(--paper); }
  .access-levels button:hover:not(.on) { color: var(--paper); }
  .access-levels button:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  .access-levels svg { flex: none; width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 1.5; stroke-linecap: round; stroke-linejoin: round; }
  .access-levels span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .access-help { margin: 0; color: var(--text-tertiary); font-size: var(--label); line-height: 1.35; }
</style>
