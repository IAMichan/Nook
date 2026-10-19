<script lang="ts">
  // Nook zelf: een bol met licht en schaduw waarvan de ogen je muis volgen. Knikt als iets klaar is.
  let { size = 22, mood = "idle" }: { size?: number; mood?: "idle" | "working" | "waiting" | "done" | "error" } = $props();
  let el: HTMLDivElement;
  let look = $state({ x: 0, y: 0 });

  function follow(e: MouseEvent) {
    if (!el) return;
    const r = el.getBoundingClientRect();
    const dx = e.clientX - (r.left + r.width / 2);
    const dy = e.clientY - (r.top + r.height / 2);
    const d = Math.max(1, Math.hypot(dx, dy));
    const reach = size * 0.09;
    look = { x: (dx / d) * Math.min(reach, d / 20), y: (dy / d) * Math.min(reach, d / 20) };
  }
</script>

<svelte:window onmousemove={follow} />

<div class="orb {mood}" bind:this={el} style="--s:{size}px">
  <span class="eye" style="transform: translate({look.x}px, {look.y}px)"></span>
  <span class="eye" style="transform: translate({look.x}px, {look.y}px)"></span>
</div>

<style>
  .orb {
    width: var(--s);
    height: var(--s);
    border-radius: 50%;
    background: radial-gradient(circle at 34% 30%, #fff 0%, var(--iris) 38%, color-mix(in srgb, var(--iris) 55%, #000) 100%);
    box-shadow: 0 0 calc(var(--s) * 0.5) color-mix(in srgb, var(--iris) 25%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: calc(var(--s) * 0.16);
    flex: none;
    transition: box-shadow 0.3s;
  }
  .eye {
    width: calc(var(--s) * 0.13);
    height: calc(var(--s) * 0.22);
    border-radius: 999px;
    background: #050507;
    transition: transform 0.08s linear;
  }
  .working { animation: breathe 1.6s ease-in-out infinite; }
  .waiting { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--amber) 55%, transparent); }
  .done { animation: nod 0.5s ease-out 2; }
  .error { box-shadow: 0 0 calc(var(--s) * 0.6) color-mix(in srgb, var(--coral) 55%, transparent); }
  @keyframes breathe { 50% { transform: scale(1.08); } }
  @keyframes nod { 40% { transform: translateY(2px); } }
</style>
