<script lang="ts">
  // This window's toast, bottom center: the kind's mark, the title and the line under it. It stays while the pointer
  // is on it, and an error can be copied in one click.
  import { toast } from "../lib/toast.svelte";

  const symbols = { success: "✓", error: "!", warning: "!", info: "i" } as const;
  let copied = $state(false);

  $effect(() => {
    toast.current;
    copied = false;
  });

  async function copy() {
    const current = toast.current;
    if (!current) return;
    await navigator.clipboard.writeText([current.title, current.detail].filter(Boolean).join("\n"));
    copied = true;
  }
</script>

{#if toast.current}
  {@const current = toast.current}
  <div
    class="toast {current.kind}"
    role={current.kind === "error" ? "alert" : "status"}
    aria-live={current.kind === "error" ? "assertive" : "polite"}
    onmouseenter={() => (toast.paused = true)}
    onmouseleave={() => (toast.paused = false)}
  >
    <span class="mark" aria-hidden="true">{symbols[current.kind]}</span>
    <div class="text">
      <div class="title">{current.title}</div>
      {#if current.detail}<div class="detail">{current.detail}</div>{/if}
    </div>
    {#if current.kind === "error" && current.detail}
      <button class="icon" title="Melding kopiëren" aria-label="Melding kopiëren" onclick={copy}>{copied ? "✓" : "⧉"}</button>
    {/if}
    <button class="icon" title="Sluiten" aria-label="Sluiten" onclick={() => toast.dismiss()}>✕</button>
  </div>
{/if}

<style>
  .toast {
    --tone: var(--iris);
    position: fixed;
    left: 50%;
    bottom: 16px;
    transform: translateX(-50%);
    z-index: 1000;
    width: max-content;
    max-width: min(440px, calc(100vw - 32px));
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 8px 6px 8px 12px;
    background: var(--graphite);
    border: 1px solid color-mix(in srgb, var(--tone) 30%, transparent);
    border-radius: 10px;
    box-shadow: 0 6px 14px rgb(0 0 0 / 45%);
    animation: rise 0.28s ease-out;
  }
  .toast.success { --tone: var(--mint); }
  .toast.error { --tone: var(--coral); }
  .toast.warning { --tone: var(--amber); }
  .mark {
    flex: none;
    width: 16px;
    height: 16px;
    margin-top: 1px;
    border-radius: 50%;
    background: var(--tone);
    color: var(--graphite);
    font-size: 10px;
    font-weight: 800;
    display: grid;
    place-items: center;
  }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; user-select: text; }
  .title { font-size: 13px; font-weight: 600; color: var(--paper); }
  .detail { font-size: 11.5px; color: var(--text2); display: -webkit-box; -webkit-line-clamp: 4; line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; }
  .icon { flex: none; width: 24px; height: 20px; padding: 0; background: transparent; border: none; color: var(--text2); font-size: 11px; }
  .icon:hover { color: var(--paper); }
  @keyframes rise { from { opacity: 0; transform: translate(-50%, 8px); } }
  @media (prefers-reduced-motion: reduce) { .toast { animation: none; } }
</style>
