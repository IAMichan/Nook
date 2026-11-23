<script lang="ts">
  // A question in its own dialog, as the Mac's `confirmationDialog` shows one: a visible title, what it means under it,
  // maybe a field, and its buttons (a destructive one in coral). On the desktop it is a Nook card with the buttons at
  // the bottom right, Escape cancelling and Return taking the bold one; inside the companion (`.phone`) it is the
  // iPhone's alert. Pass the answer first and Cancel last: the first button sits on the right (on top on the phone).
  // Escape closes without an answer.
  import { onBack } from "../../lib/mobile";
  export interface DialogButton { label: string; destructive?: boolean; bold?: boolean; onselect: () => void }
  let { title, message, field = $bindable(), placeholder, buttons, onclose, remember, remembered = $bindable(false) }: {
    title?: string;
    message?: string;
    field?: string;
    placeholder?: string;
    buttons: DialogButton[];
    onclose: () => void;
    /** A box under the message ("Don't ask again"); its state is `remembered`. */
    remember?: string;
    remembered?: boolean;
  } = $props();
  $effect(() => onBack(() => (onclose(), true)));

  let box: HTMLDivElement | undefined = $state();
  // Focus lands on the field, else on the bold (or last) button, so Return answers and Escape cancels at once.
  $effect(() => {
    const target = box?.querySelector<HTMLElement>("input") ?? box?.querySelector<HTMLElement>("button.bold") ?? box?.querySelector<HTMLElement>(".buttons button");
    target?.focus();
  });

  function choose(b: DialogButton) {
    b.onselect();
    onclose();
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      onclose();
    } else if (e.key === "Enter" && e.target instanceof HTMLInputElement) {
      const bold = buttons.find((b) => b.bold);
      if (bold) { e.preventDefault(); choose(bold); }
    }
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="scrim" onkeydown={keydown}>
  <div class="alert" role="alertdialog" aria-modal="true" aria-label={title} bind:this={box}>
    <div class="body">
      {#if title}<strong>{title}</strong>{/if}
      {#if message}<p>{message}</p>{/if}
      {#if remember}<label class="remember"><input type="checkbox" bind:checked={remembered} />{remember}</label>{/if}
      {#if field !== undefined}<input bind:value={field} {placeholder} aria-label={placeholder ?? title} />{/if}
    </div>
    <div class="buttons" class:row={buttons.length === 2}>
      {#each buttons as b (b.label)}
        <button class:destructive={b.destructive} class:bold={b.bold} onclick={() => choose(b)}>{b.label}</button>
      {/each}
    </div>
  </div>
</div>

<style>
  /* The desktop: a Nook card over a dimmed window. */
  .scrim { position: fixed; inset: 0; z-index: 70; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; padding: var(--space-24); animation: fade 160ms ease-out; }
  .alert { width: min(380px, 100%); background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); overflow: hidden; animation: pop 180ms cubic-bezier(0.2, 0.9, 0.3, 1.1); }
  .body { padding: var(--space-16) var(--space-16) var(--space-12); display: flex; flex-direction: column; gap: var(--space-6); }
  strong { font: var(--text-title); color: var(--paper); }
  p { margin: 0; font: var(--text-detail); color: var(--text2); white-space: pre-line; }
  input:not([type="checkbox"]) { margin-top: var(--space-6); }
  .remember { display: flex; align-items: center; gap: var(--space-6); margin-top: var(--space-6); font: var(--text-detail); color: var(--text2); cursor: pointer; }
  .buttons { display: flex; flex-direction: row-reverse; justify-content: flex-start; gap: var(--space-8); padding: 0 var(--space-16) var(--space-16); }
  .buttons button.bold { background: var(--iris); color: var(--on-iris); border-color: transparent; font-weight: 600; }
  .buttons button.destructive { background: color-mix(in srgb, var(--coral) 16%, var(--smoke)); color: var(--coral); border-color: color-mix(in srgb, var(--coral) 35%, transparent); font-weight: 600; }

  /* The companion: the iPhone's alert, its buttons stacked (side by side when there are two, the first on the right). */
  :global(.phone) .alert { width: 270px; background: rgba(37, 37, 37, 0.96); backdrop-filter: blur(30px); border: none; border-radius: 14px; box-shadow: none; text-align: center; animation-duration: 220ms; }
  :global(.phone) .body { padding: 20px 16px 16px; gap: 4px; }
  :global(.phone) strong { font: 600 17px var(--font); }
  :global(.phone) p { font: 400 13px/1.35 var(--font); color: var(--paper); }
  :global(.phone) input { margin-top: 12px; padding: 7px 8px !important; background: #1c1c1e !important; border: 0.5px solid rgba(255, 255, 255, 0.15) !important; border-radius: 7px; font: 400 13px var(--font) !important; text-align: left; }
  :global(.phone) .buttons { flex-direction: column; gap: 0; padding: 0; }
  :global(.phone) .buttons.row { flex-direction: row-reverse; }
  :global(.phone) .buttons button { flex: 1; height: 44px; background: none !important; border: none !important; border-radius: 0; border-top: 0.5px solid rgba(255, 255, 255, 0.12) !important; color: var(--blue) !important; font: 400 17px var(--font) !important; }
  :global(.phone) .buttons.row button + button { border-right: 0.5px solid rgba(255, 255, 255, 0.12) !important; }
  :global(.phone) .buttons button.bold { font-weight: 600 !important; }
  :global(.phone) .buttons button.destructive { color: var(--coral) !important; }
  @keyframes fade { from { opacity: 0; } }
  @keyframes pop { from { opacity: 0; transform: scale(0.96); } }
  :global(.phone) .alert { animation-name: phone-pop; }
  @keyframes phone-pop { from { opacity: 0; transform: scale(1.1); } }
</style>
