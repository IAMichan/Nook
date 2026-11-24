<script lang="ts" module>
  export type { ChatPoll } from "../../lib/chat-poll";
</script>

<script lang="ts">
  // A poll in a chat bubble, the same in every chat (`ChatPollView`): its question, each option with a bar for its share
  // and how many chose it, your own choice ticked, and "View votes" where the app names the voters. With `onvote` a click
  // votes (the counts move at once); without, the poll says to vote in the app.
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { choiceAfter, voting, type ChatPoll } from "../../lib/chat-poll";

  let { poll, onvote }: { poll: ChatPoll; onvote?: (choice: string[]) => Promise<void> } = $props();

  let pending = $state<ChatPoll | null>(null);
  let showVoters = $state(false);
  $effect(() => {
    void poll;
    pending = null;
  });
  const shown = $derived(pending ?? poll);
  const total = $derived(shown.options.reduce((n, o) => n + o.votes, 0));
  const counted = $derived(shown.unknownCounts !== true);
  const partial = $derived(!counted && total > 0);
  const showsCounts = $derived(counted || partial);
  const namesVoters = $derived(shown.options.some((o) => (o.voters ?? []).length > 0));
  const you = (name: string) => (name === "You" ? tr("Jij", "You") : name);

  async function pick(option: string) {
    if (!onvote) return;
    const choice = choiceAfter(shown, option);
    pending = voting(shown, choice);
    try {
      await onvote(choice);
    } catch {
      pending = null;
    }
  }
</script>

<div class="poll">
  <div class="question"><Ico name="chart-column" size={12} stroke={2.4} /><span>{shown.question}</span></div>
  {#if shown.options.length}<span class="caption">{shown.multiple ? tr("Kies een of meer antwoorden", "Choose one or more answers") : tr("Kies één antwoord", "Choose one answer")}</span>{/if}
  {#each shown.options as o (o.text)}
    {@const share = total === 0 ? 0 : o.votes / total}
    <button class="option" disabled={!onvote} aria-pressed={o.chosen} onclick={() => pick(o.text)}>
      <span class="line">
        <span class="mark" class:chosen={o.chosen}><Ico name={o.chosen ? "circle-check" : shown.multiple ? "square" : "circle"} size={13} stroke={2} /></span>
        <span class="text">{o.text}</span>
        {#if showsCounts}<span class="count">{o.votes}</span>{/if}
      </span>
      {#if showsCounts}<span class="bar"><span class="fill" class:chosen={o.chosen} style:width="{share * 100}%"></span></span>{/if}
      {#if showVoters && o.voters?.length}<span class="caption">{o.voters.map(you).join(", ")}</span>{/if}
    </button>
  {/each}
  <span class="foot caption">
    {#if showsCounts && shown.options.length}<span>{tr("{n} stemmen", "{n} votes", { n: total })}</span>{/if}
    {#if namesVoters}<button class="link" onclick={() => (showVoters = !showVoters)}>{showVoters ? tr("Verberg stemmen", "Hide votes") : tr("Bekijk stemmen", "View votes")}</button>{/if}
    {#if !onvote}<span class="spacer"></span><span>{tr("Stem in de app", "Vote in the app")}</span>{/if}
  </span>
  {#if partial}<span class="caption">{tr("Eerdere stemmen kunnen ontbreken: Nook ziet alleen de stemmen die binnenkwamen terwijl het draaide.", "Earlier votes may be missing: Nook only sees the votes that came in while it was running.")}</span>{/if}
</div>

<style>
  .poll { display: flex; flex-direction: column; gap: var(--space-6); width: min(260px, 100%); }
  .question { display: flex; align-items: baseline; gap: var(--space-4); font: var(--text-strong); color: var(--paper); }
  .question :global(svg) { color: var(--text2); flex: none; }
  .caption { font: var(--text-detail); color: var(--text3); }
  .option { display: flex; flex-direction: column; gap: var(--space-4); padding: 0; border: 0; background: transparent; text-align: left; color: inherit; }
  .option:disabled { cursor: default; opacity: 1; }
  .line { display: flex; align-items: baseline; gap: var(--space-6); }
  .mark { color: var(--text2); display: inline-flex; }
  .mark.chosen { color: var(--mint); }
  .text { flex: 1; font: var(--text-body); color: var(--paper); }
  .count { font: var(--text-label); color: var(--text2); font-variant-numeric: tabular-nums; }
  .bar { height: 4px; border-radius: var(--radius-control); background: var(--line); overflow: hidden; }
  .fill { display: block; height: 100%; background: var(--text2); }
  .fill.chosen { background: var(--mint); }
  .foot { display: flex; align-items: center; gap: var(--space-6); }
  .spacer { flex: 1; }
  .link { padding: 0; border: 0; background: transparent; color: var(--blue); font: var(--text-detail); }
</style>
