<!-- A terminal next to the chat (a command `run_command` started): same header, folder bar, and terminals as Agents. -->
<script lang="ts">
  import { tr } from "../lib/i18n.svelte";
  import Terminals from "../views/workspace/Terminals.svelte";
  import Icon from "./Icon.svelte";

  let { folder, focusId = null, onclose }: { folder: string; focusId?: string | null; onclose: () => void } = $props();
</script>

<div class="chat-terminal">
  <header class="head">
    <span class="title">
      <Icon name="terminal" size={14} />
      <span>{tr("Terminals", "Terminals")}</span>
    </span>
    <span class="folder faint" title={folder}>{folder}</span>
    <button
      type="button"
      class="ghost icon-button"
      onclick={onclose}
      title={tr("Terminal sluiten", "Close terminal")}
      aria-label={tr("Terminal sluiten", "Close terminal")}
    >
      <Icon name="x" size={14} />
    </button>
  </header>
  <div class="body">
    {#key folder}
      <Terminals {folder} {focusId} />
    {/key}
  </div>
</div>

<style>
  .chat-terminal { display: flex; flex-direction: column; height: 100%; min-height: 0; min-width: 0; }
  .head { display: flex; align-items: center; gap: 8px; min-height: 44px; padding: 0 12px; border-bottom: 1px solid var(--border); flex: none; }
  .title { display: inline-flex; align-items: center; gap: 6px; font: var(--text-control); font-weight: 600; color: var(--paper); flex: none; }
  .folder { flex: 1; min-width: 0; font: var(--text-label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-align: right; }
  .icon-button { display: grid; place-items: center; width: 26px; height: 26px; padding: 0; flex: none; border: 0; border-radius: var(--radius-control); color: var(--text2); }
  .icon-button:hover { background: var(--row-hover); color: var(--paper); }
  .body { flex: 1; min-height: 0; padding: 10px 12px; display: flex; flex-direction: column; }
</style>
