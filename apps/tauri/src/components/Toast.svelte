<script lang="ts">
  // This window's toasts, top right under the title bar (as in the Mac app), as a stack: the newest in front, each
  // older one a step smaller and peeking out under it with its content hidden. With the pointer on the stack it spreads
  // out into a column and every toast stays. A toast shows the kind's mark, the title and the line under it, and an
  // error can be copied in one click.
  import { fly } from "svelte/transition";
  import { toast } from "../lib/toast.svelte";
  import { tr } from "../lib/i18n.svelte";

  const symbols = { success: "✓", error: "!", warning: "!", info: "i" } as const;
  /// How far each older toast peeks out, how much smaller each step back is, and the room between spread-out toasts.
  const PEEK = 12;
  const SHRINK = 0.06;
  const GAP = 8;
  /// A toast's padding and border around its row.
  const FRAME = 18;
  const reduceMotion = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

  let copied = $state<number | null>(null);
  let expanded = $state(false);
  /// Each toast's row height, unaffected by the stack.
  let rows = $state<Record<number, number>>({});

  /// Newest first: depth 0 is in front.
  const stack = $derived([...toast.shown].reverse());
  const full = (id: number) => (rows[id] ?? 0) + FRAME;
  const front = $derived(stack.length ? full(stack[0].id) : 0);
  const spread = $derived(expanded && stack.length > 1);

  function scale(depth: number) {
    return spread ? 1 : 1 - depth * SHRINK;
  }

  function offset(depth: number) {
    if (depth === 0) return 0;
    if (spread) return stack.slice(0, depth).reduce((sum, t) => sum + full(t.id), 0) + depth * GAP;
    return depth * PEEK + front * (1 - scale(depth));
  }

  const height = $derived(
    stack.length === 0 ? 0 : spread ? offset(stack.length - 1) + full(stack[stack.length - 1].id) : front + (stack.length - 1) * PEEK,
  );

  function hover(inside: boolean) {
    expanded = inside;
    toast.paused = inside;
  }

  async function copy(id: number) {
    const current = toast.shown.find((t) => t.id === id);
    if (!current) return;
    await navigator.clipboard.writeText([current.title, current.detail].filter(Boolean).join("\n"));
    copied = id;
  }
</script>

{#if stack.length}
  <div
    class="stack"
    style:height="{height}px"
    role="region"
    aria-label={tr("Meldingen", "Notifications")}
    onmouseenter={() => hover(true)}
    onmouseleave={() => hover(false)}
  >
    {#each stack as current, depth (current.id)}
      {@const covered = !spread && depth > 0}
      <div
        class="toast {current.kind}"
        class:covered
        role={current.kind === "error" ? "alert" : "status"}
        aria-live={current.kind === "error" ? "assertive" : "polite"}
        aria-hidden={covered}
        inert={covered}
        style:z-index={stack.length - depth}
        style:height={covered ? `${front}px` : null}
        style:transform="translateY({offset(depth)}px) scale({scale(depth)})"
        transition:fly={{ x: reduceMotion ? 0 : 380, duration: 280 }}
      >
        <div class="row" bind:offsetHeight={rows[current.id]}>
          <span class="mark" aria-hidden="true">{symbols[current.kind]}</span>
          <div class="text">
            <div class="title">{current.title}</div>
            {#if current.detail}<div class="detail">{current.detail}</div>{/if}
          </div>
          {#if current.action}
            <button class="act" onclick={() => toast.act(current.id)}>{current.action.label}</button>
          {/if}
          {#if current.kind === "error" && current.detail}
            <button class="icon" title={tr("Melding kopiëren", "Copy message")} aria-label={tr("Melding kopiëren", "Copy message")} onclick={() => copy(current.id)}>
              {copied === current.id ? "✓" : "⧉"}
            </button>
          {/if}
          <button class="icon" title={tr("Sluiten", "Close")} aria-label={tr("Sluiten", "Close")} onclick={() => toast.dismiss(current.id)}>✕</button>
        </div>
      </div>
    {/each}
  </div>
{/if}

<style>
  .stack {
    position: fixed;
    top: 48px;
    right: 16px;
    z-index: 1000;
    width: min(360px, calc(100vw - 32px));
    transition: height 0.24s ease-out;
  }
  .toast {
    --tone: var(--iris);
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    box-sizing: border-box;
    overflow: hidden;
    padding: 8px 6px 8px 12px;
    background: var(--graphite);
    border: 1px solid color-mix(in srgb, var(--tone) 30%, transparent);
    border-radius: 10px;
    box-shadow: 0 6px 14px rgb(0 0 0 / 45%);
    transform-origin: top center;
    transition: transform 0.28s cubic-bezier(0.2, 0.8, 0.2, 1), height 0.28s ease-out;
  }
  .toast.success { --tone: var(--mint); }
  .toast.error { --tone: var(--coral); }
  .toast.warning { --tone: var(--amber); }
  .row { display: flex; align-items: flex-start; gap: 8px; transition: opacity 0.2s; }
  .covered .row { opacity: 0; }
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
  .act { flex: none; align-self: center; padding: 3px 10px; font-size: 12px; font-weight: 600; border-radius: 999px; background: color-mix(in srgb, var(--tone) 16%, transparent); border: 1px solid color-mix(in srgb, var(--tone) 40%, transparent); color: var(--paper); }
  .icon:hover { color: var(--paper); }
  @media (prefers-reduced-motion: reduce) { .stack, .toast, .row { transition: none; } }
</style>
