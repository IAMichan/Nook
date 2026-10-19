<script lang="ts">
  // Een schermdeel: trek een kader over de schermafbeelding. Return of Vraag Nook geeft het aan de chat, Kopiëren zet
  // het op het klembord, Esc annuleert.
  import { services } from "../../lib/services";

  let image = $state<string | null>(null);
  let start = $state<{ x: number; y: number } | null>(null);
  let end = $state<{ x: number; y: number } | null>(null);
  let dragging = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    services.partImage().then((i) => (image = i));
  });

  const rect = $derived(
    start && end
      ? { x: Math.min(start.x, end.x), y: Math.min(start.y, end.y), w: Math.abs(end.x - start.x), h: Math.abs(end.y - start.y) }
      : null,
  );

  function down(e: PointerEvent) {
    if ((e.target as HTMLElement).closest("button")) return;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    start = { x: e.clientX, y: e.clientY };
    end = start;
    dragging = true;
  }

  function move(e: PointerEvent) {
    if (dragging) end = { x: e.clientX, y: e.clientY };
  }

  function up() {
    dragging = false;
  }

  async function done(copy: boolean) {
    if (!rect || rect.w < 4 || rect.h < 4) return;
    const W = window.innerWidth;
    const H = window.innerHeight;
    try {
      await services.partFinish(rect.x / W, rect.y / H, rect.w / W, rect.h / H, copy);
    } catch (e) {
      error = String(e);
    }
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Escape") services.partCancel();
    if (e.key === "Enter") done(false);
  }
</script>

<svelte:window onkeydown={key} />

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="part" style={image ? `background-image:url(${image})` : ""} onpointerdown={down} onpointermove={move} onpointerup={up}>
  <div class="shade" class:has={!!rect}></div>
  {#if rect}
    <div class="frame" style="left:{rect.x}px;top:{rect.y}px;width:{rect.w}px;height:{rect.h}px;{image ? `background-image:url(${image});background-position:-${rect.x}px -${rect.y}px` : ''}"></div>
    {#if !dragging && rect.w > 4 && rect.h > 4}
      <div class="tools" style="left:{rect.x}px;top:{Math.min(rect.y + rect.h + 8, window.innerHeight - 48)}px">
        <button class="primary" onclick={() => done(false)}>Vraag Nook</button>
        <button onclick={() => done(true)}>Kopiëren</button>
        <button class="ghost" onclick={() => services.partCancel()}>Annuleren</button>
      </div>
    {/if}
  {:else}
    <div class="hint">Trek een kader om een stuk van je scherm. Esc annuleert.</div>
  {/if}
  {#if error}<div class="hint err">{error}</div>{/if}
</div>

<style>
  .part { position: fixed; inset: 0; cursor: crosshair; background-size: 100% 100%; background-color: #000; user-select: none; }
  .shade { position: absolute; inset: 0; background: rgba(0, 0, 0, 0.35); pointer-events: none; }
  .frame { position: absolute; border: 2px solid var(--paper); box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.5); background-size: 100vw 100vh; pointer-events: none; }
  .tools { position: absolute; display: flex; gap: 6px; background: var(--notch); padding: 6px; border-radius: 12px; border: 1px solid var(--line2); cursor: default; }
  .hint { position: absolute; top: 24px; left: 50%; transform: translateX(-50%); background: var(--notch); padding: 8px 14px; border-radius: 999px; border: 1px solid var(--line2); pointer-events: none; }
  .hint.err { top: 64px; color: var(--coral); }
</style>
