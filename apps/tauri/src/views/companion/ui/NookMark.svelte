<script lang="ts">
  // Nook's face (`NookMark`): a pearl sphere with two eyes that breathes and blinks now and then; a tap squishes it.
  import { onMount } from "svelte";
  let { size = 30, still = false }: { size?: number; still?: boolean } = $props();
  let blink = $state(false);
  let squish = $state(false);
  const id = `nm${Math.random().toString(36).slice(2, 8)}`;
  onMount(() => {
    if (still || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let timer: ReturnType<typeof setTimeout>;
    const next = () => {
      timer = setTimeout(() => {
        blink = true;
        setTimeout(() => (blink = false), 220);
        next();
      }, 3500 + Math.random() * 2000);
    };
    next();
    return () => clearTimeout(timer);
  });
  export function poke() {
    squish = true;
    setTimeout(() => (squish = false), 160);
  }
  const eyeW = $derived(size * 0.095);
  const eyeH = $derived(size * 0.22);
  const gap = $derived(size * 0.16);
</script>

<span class="mark" class:still class:squish style:width="{size}px" style:height="{size}px" aria-hidden="true">
  <span class="glow" style:filter="blur({size * 0.12}px)"></span>
  <svg viewBox="0 0 100 100" width={size} height={size}>
    <defs>
      <radialGradient id="{id}s" cx="34%" cy="26%" r="65%">
        <stop offset="0" stop-color="#ffffff" /><stop offset="0.35" stop-color="#f4f3f7" /><stop offset="0.75" stop-color="#cac8d2" /><stop offset="1" stop-color="#8c8b96" />
      </radialGradient>
      <linearGradient id="{id}o" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0" /><stop offset="1" stop-color="#fff" stop-opacity="0.22" /></linearGradient>
    </defs>
    <circle cx="50" cy="50" r="50" fill="url(#{id}s)" />
    <circle cx="50" cy="50" r="50" fill="url(#{id}o)" />
  </svg>
  <span class="eyes" style:gap="{gap}px" style:margin-top="{-size * 0.04}px" class:blink>
    {#each [0, 1] as i (i)}
      <span class="eye" style:width="{eyeW}px" style:height="{eyeH}px"><span class="light" style:width="{size * 0.035}px" style:height="{size * 0.035}px" style:left="{size * 0.015 + eyeW / 2 - size * 0.0175}px" style:top="{size * 0.025}px"></span></span>
    {/each}
  </span>
</span>

<style>
  .mark { position: relative; display: inline-flex; align-items: center; justify-content: center; flex: none; animation: breathe 2.2s ease-in-out infinite alternate; transition: transform 0.16s; }
  .mark.still { animation: none; }
  .mark.squish { transform: scale(1.14, 0.86); animation: none; }
  @keyframes breathe { from { transform: scale(0.985, 1.015); } to { transform: scale(1.015, 0.985); } }
  .glow { position: absolute; inset: -5%; border-radius: 50%; background: rgba(244, 243, 247, 0.18); }
  svg { position: absolute; inset: 0; filter: drop-shadow(0 1px 2px rgba(244, 243, 247, 0.22)); }
  .eyes { position: relative; display: flex; transition: transform 0.1s; }
  .eyes.blink { transform: scaleY(0.08); }
  .eye { position: relative; background: #0b0b0d; border-radius: 999px; }
  .light { position: absolute; border-radius: 50%; background: rgba(255, 255, 255, 0.85); }
  @media (prefers-reduced-motion: reduce) { .mark { animation: none; } }
</style>
