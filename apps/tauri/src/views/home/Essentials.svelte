<script lang="ts">
  // Your essentials: the features you pinned to Home, in your order. One click opens the real feature.
  import { fly, scale } from "svelte/transition";
  import { flip } from "svelte/animate";
  import { cubicOut } from "svelte/easing";
  import Icon from "../../components/Icon.svelte";
  import type { Feature } from "../../lib/features";
  import { tr } from "../../lib/i18n.svelte";

  let { features, onopen, oncustomize, compact = false }: { features: Feature[]; onopen: (f: Feature) => void; oncustomize: () => void; compact?: boolean } = $props();
</script>

<div class="essentials" class:compact>
  <div class="head">
    <span class="eyebrow">{tr("Je essentials", "Your essentials")}</span>
    <button class="ghost customize" onclick={oncustomize}>{tr("Aanpassen", "Customize")}</button>
  </div>
  <div class="grid">
    {#each features as feature, index (feature.id)}
      <button class="tile" onclick={() => onopen(feature)} animate:flip={{ duration: 280, easing: cubicOut }} in:fly={{ y: 10, duration: 360, delay: Math.min(index, 8) * 40, easing: cubicOut }} out:scale={{ duration: 180, start: 0.94 }}>
        <span class="glyph"><Icon name={feature.icon} size={19} /></span>
        <span class="name">{tr(...feature.title)}</span>
        <span class="hint">{tr(...feature.hint)}</span>
      </button>
    {/each}
    <button class="tile add" onclick={oncustomize}>
      <span class="glyph"><Icon name="plus" size={18} /></span>
      <span class="name">{features.length ? tr("Toevoegen", "Add feature") : tr("Kies je essentials", "Choose your essentials")}</span>
      <span class="hint">{tr("Wat jij het meest gebruikt", "What you use most")}</span>
    </button>
  </div>
</div>

<style>
  .head { display: flex; align-items: center; padding: 0 4px 14px; min-height: 28px; }
  .eyebrow { font-size: 11px; font-weight: 650; letter-spacing: 1.4px; text-transform: uppercase; color: var(--text3); }
  .customize { margin-left: auto; font-size: 12px; padding: 4px 10px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 12px; }
  .tile {
    display: flex; flex-direction: column; align-items: flex-start; gap: 4px; text-align: left; min-height: 118px; padding: 16px;
    border-radius: var(--radius-panel); border: 1px solid var(--line);
    background: linear-gradient(160deg, color-mix(in srgb, var(--smoke) 78%, transparent), color-mix(in srgb, var(--graphite) 70%, transparent));
    box-shadow: 0 1px 0 #ffffff07 inset;
    transition: transform 220ms cubic-bezier(.2, .8, .2, 1), border-color 220ms ease, background 220ms ease, box-shadow 220ms ease;
  }
  .tile:hover:not(:disabled) {
    transform: translateY(-2px); border-color: var(--line2);
    background: linear-gradient(160deg, color-mix(in srgb, var(--row-hover) 90%, transparent), color-mix(in srgb, var(--smoke) 70%, transparent));
    box-shadow: 0 1px 0 #ffffff0a inset, 0 18px 40px -24px #000c;
  }
  .tile:active:not(:disabled) { transform: translateY(0) scale(.99); }
  .glyph { width: 36px; height: 36px; border-radius: 11px; display: grid; place-items: center; margin-bottom: auto; color: var(--paper); background: color-mix(in srgb, var(--paper) 7%, transparent); }
  .name { font-size: 14px; font-weight: 600; margin-top: 14px; }
  .hint { font-size: 11.5px; color: var(--text3); }
  .add { background: transparent; border-style: dashed; box-shadow: none; }
  .add .glyph { background: transparent; color: var(--text3); }
  .add .name { color: var(--text2); font-weight: 550; }
  .compact .head { padding-bottom: 8px; }
  .compact .grid { grid-template-columns: repeat(auto-fill, minmax(118px, 1fr)); gap: 8px; }
  .compact .tile { min-height: 0; padding: 12px; border-radius: var(--radius); }
  .compact .glyph { width: 30px; height: 30px; border-radius: 10px; margin-bottom: 0; }
  .compact .name { font-size: 13px; margin-top: 10px; }
  .compact .hint { display: none; }
  @container (max-width: 600px) {
    .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
    .tile { min-height: 104px; padding: 14px; }
    .compact .grid { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
    .compact .tile { min-height: 0; padding: 12px; }
  }
</style>
