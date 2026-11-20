<script lang="ts">
  // The emoji on a message as one pill under the bubble (`ReactionChips`): up to three emoji, how many reacted in all,
  // tinted mint when one is yours. A click shows who put which emoji there (`ReactionPeopleView`); your own row takes
  // yours back, another's adds the same one from you, where the chat can be answered.
  import type { ChatReaction } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";

  let { reactions, onreact }: { reactions: ChatReaction[]; onreact?: (emoji: string) => void } = $props();
  const mine = $derived(reactions.some((r) => r.mine));
  const total = $derived(reactions.reduce((n, r) => n + Math.max(r.from.length, 1), 0));
  const you = () => tr("Jij", "You");
  const summary = $derived(reactions.map((r) => `${r.emoji} ${r.from.map((w) => w || you()).join(", ")}`).join(" · "));
  let anchor = $state<DOMRect | null>(null);
  const rows = $derived<MenuItem[][]>([
    reactions.flatMap((r) =>
      [...r.from].sort((a, b) => (a ? 1 : 0) - (b ? 1 : 0)).map((who) => ({
        label: `${r.emoji}  ${who || you()}`,
        detail: !onreact ? undefined : who ? tr("Ook toevoegen", "Add yours too") : tr("Tik om te verwijderen", "Click to remove"),
        onselect: onreact ? () => onreact!(who || !r.mine ? r.emoji : "") : undefined,
      })),
    ),
  ]);
</script>

{#if reactions.length}
  <button class="pill" class:mine title={summary} aria-label={summary} onclick={(e) => (anchor = (e.currentTarget as HTMLElement).getBoundingClientRect())}>
    <span class="emoji">{#each reactions.slice(0, 3) as r (r.emoji)}<span>{r.emoji}</span>{/each}</span>
    {#if total > 1}<span class="count">{total}</span>{/if}
  </button>
{/if}
{#if anchor}<Menu sections={rows} {anchor} onclose={() => (anchor = null)} />{/if}

<style>
  .pill { display: inline-flex; align-items: center; gap: var(--space-2); padding: var(--space-2) var(--space-6); border: 0; border-radius: var(--radius-chip); background: var(--chat-theirs); color: inherit; }
  .pill.mine { background: color-mix(in srgb, var(--mint) 18%, var(--chat-theirs)); }
  .pill:hover:not(:disabled) { border: 0; filter: brightness(1.15); }
  .emoji { display: inline-flex; font: var(--text-control); font-weight: 400; }
  .count { font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text2); }
  .mine .count { color: var(--mint); }
</style>
