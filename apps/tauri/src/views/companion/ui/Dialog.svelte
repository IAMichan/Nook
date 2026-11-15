<script lang="ts">
  // An alert as the iPhone shows one: a title, a message, maybe a field, and its buttons (a destructive one in coral).
  import { onBack } from "../../../lib/mobile";
  let { title, message, field = $bindable(), placeholder, buttons, onclose }: {
    title?: string;
    message?: string;
    field?: string;
    placeholder?: string;
    buttons: { label: string; destructive?: boolean; bold?: boolean; onselect: () => void }[];
    onclose: () => void;
  } = $props();
  $effect(() => onBack(() => (onclose(), true)));
</script>

<div class="scrim">
  <div class="alert" role="alertdialog">
    <div class="body">
      {#if title}<strong>{title}</strong>{/if}
      {#if message}<p>{message}</p>{/if}
      {#if field !== undefined}<input bind:value={field} {placeholder} />{/if}
    </div>
    <div class="buttons" class:row={buttons.length === 2}>
      {#each buttons as b (b.label)}
        <button class:destructive={b.destructive} class:bold={b.bold} onclick={() => { b.onselect(); onclose(); }}>{b.label}</button>
      {/each}
    </div>
  </div>
</div>

<style>
  .scrim { position: fixed; inset: 0; z-index: 70; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; padding: 24px; animation: fade 200ms; }
  .alert { width: 270px; background: rgba(37, 37, 37, 0.96); backdrop-filter: blur(30px); border-radius: 14px; overflow: hidden; text-align: center; animation: pop 220ms cubic-bezier(0.2, 0.9, 0.3, 1.1); }
  .body { padding: 20px 16px 16px; display: flex; flex-direction: column; gap: 4px; }
  strong { font: 600 17px var(--font); color: var(--paper); }
  p { margin: 0; font: 400 13px/1.35 var(--font); color: var(--paper); }
  input { margin-top: 12px; padding: 7px 8px !important; background: #1c1c1e !important; border: 0.5px solid rgba(255, 255, 255, 0.15) !important; border-radius: 7px; font: 400 13px var(--font) !important; text-align: left; }
  .buttons { display: flex; flex-direction: column; }
  .buttons.row { flex-direction: row-reverse; }
  .buttons button { flex: 1; height: 44px; border-top: 0.5px solid rgba(255, 255, 255, 0.12) !important; color: var(--blue) !important; font: 400 17px var(--font) !important; }
  .buttons.row button + button { border-right: 0.5px solid rgba(255, 255, 255, 0.12) !important; }
  .buttons button.bold { font-weight: 600 !important; }
  .buttons button.destructive { color: var(--coral) !important; }
  @keyframes fade { from { opacity: 0; } }
  @keyframes pop { from { opacity: 0; transform: scale(1.1); } }
</style>
