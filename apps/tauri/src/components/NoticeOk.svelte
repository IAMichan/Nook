<script lang="ts">
  // The "OK" that closes an agent notice at once (NookAcknowledgeButton on the Mac): the white main button of a notice.
  // With `left` set, a ring in it shows what is left of the time before the notice closes by itself (1 full, 0 empty).
  let { left = null, compact = false, onclick }: { left?: number | null; compact?: boolean; onclick: () => void } = $props();
  const size = $derived(compact ? 16 : 18);
  const radius = $derived(size / 2 - 2.6);
  const circumference = $derived(2 * Math.PI * radius);
</script>

<button class="ok" class:compact class:ring={left !== null} {onclick}>
  {#if left !== null}
    <svg width={size} height={size} viewBox="0 0 {size} {size}" aria-hidden="true">
      <circle cx={size / 2} cy={size / 2} r={radius} class="track" />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={radius}
        class="left"
        stroke-dasharray={circumference}
        stroke-dashoffset={circumference * (1 - Math.max(0, Math.min(1, left)))}
        transform="rotate(-90 {size / 2} {size / 2})"
      />
    </svg>
  {/if}
  Oké
</button>

<style>
  .ok {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 38px;
    padding: 0 18px;
    border: none;
    border-radius: 999px;
    background: var(--paper);
    color: var(--ink);
    font-weight: 600;
    font-size: 14px;
    white-space: nowrap;
    flex: none;
  }
  .ok:hover { background: #fff; }
  .ok.ring { padding-left: 9px; }
  .ok.compact { height: 30px; padding: 0 14px; font-size: 13px; }
  .ok.compact.ring { padding-left: 7px; }
  circle { fill: none; stroke-width: 2.2; }
  .track { stroke: color-mix(in srgb, var(--ink) 14%, transparent); }
  .left { stroke: var(--ink); stroke-linecap: round; transition: stroke-dashoffset 0.1s linear; }
</style>
