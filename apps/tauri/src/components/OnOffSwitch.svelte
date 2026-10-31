<script lang="ts">
  // A pill switch with two labelled halves (Enabled / Disabled) and a knob that slides behind the chosen one. On is
  // mint (Nook's "ok"), off is a neutral grey.
  import { tr } from "../lib/i18n.svelte";

  let {
    on,
    onchange,
    disabled = false,
    label,
    onText,
    offText,
    title,
  }: {
    /// `undefined` while loading: no knob yet.
    on: boolean | undefined;
    onchange: (on: boolean) => void;
    disabled?: boolean;
    /// What it switches, for screen readers.
    label: string;
    onText?: string;
    offText?: string;
    title?: string;
  } = $props();

  const pick = (value: boolean) => {
    if (!disabled && value !== on) onchange(value);
  };

  function keys(e: KeyboardEvent) {
    if (e.key === "ArrowLeft" || e.key === "ArrowRight" || e.key === " " || e.key === "Enter") {
      e.preventDefault();
      pick(e.key === "ArrowLeft" ? true : e.key === "ArrowRight" ? false : !on);
    }
  }
</script>

<div
  class="switch"
  class:on={on === true}
  class:off={on === false}
  class:disabled
  role="switch"
  aria-checked={!!on}
  aria-label={label}
  aria-disabled={disabled}
  tabindex={disabled ? -1 : 0}
  {title}
  onkeydown={keys}
>
  <span class="knob" aria-hidden="true"></span>
  <button type="button" tabindex="-1" class:chosen={on === true} {disabled} onclick={() => pick(true)}>{onText ?? tr("Aan", "Enabled")}</button>
  <button type="button" tabindex="-1" class:chosen={on === false} {disabled} onclick={() => pick(false)}>{offText ?? tr("Uit", "Disabled")}</button>
</div>

<style>
  .switch { position: relative; display: inline-grid; grid-template-columns: 1fr 1fr; padding: 3px; border-radius: 999px; background: var(--field); border: 1px solid var(--line2); flex: none; user-select: none; }
  .switch:focus-visible { outline: 2px solid var(--iris); outline-offset: 2px; }
  .knob { position: absolute; top: 3px; bottom: 3px; left: 3px; width: calc(50% - 3px); border-radius: 999px; opacity: 0; transition: transform .22s cubic-bezier(.3, .7, .2, 1), background-color .22s ease, opacity .15s ease; }
  .switch.on .knob { opacity: 1; background: var(--mint); box-shadow: var(--shadow-control); }
  .switch.off .knob { opacity: 1; background: color-mix(in srgb, var(--text3) 45%, var(--smoke)); box-shadow: var(--shadow-control); transform: translateX(100%); }
  button { position: relative; z-index: 1; background: none; border: none; border-radius: 999px; padding: 7px 16px; font-size: 12.5px; font-weight: 600; color: var(--text3); white-space: nowrap; transition: color .2s ease; }
  button:hover:not(:disabled) { background: none; color: var(--text2); }
  .switch.on button.chosen { color: var(--ink); }
  .switch.off button.chosen { color: var(--paper); }
  .switch.disabled { opacity: .5; }
  @media (prefers-reduced-motion: reduce) {
    .knob, button { transition: none; }
  }
</style>
