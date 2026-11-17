<script lang="ts">
  // While the computer cannot be reached, in every conversation where it stays in sight (over the composer, or over
  // what waits on you), as the iPhone's `OfflineStrip`: that nothing new comes in and since when, and what happens to
  // what you do here. Amber, so it never reads as live. It waits a moment, so a short drop passes unseen.
  import { offlineWords, writingWaits, type ClientView } from "../../../lib/companion";
  import { tr } from "../../../lib/i18n.svelte";
  import Banner from "../../../components/ui/Banner.svelte";
  /** `sends`: you write here; `reads`: you only read here; `answers`: an approval or a question waits on you. */
  let { view, kind = "sends" }: { view: ClientView; kind?: "sends" | "reads" | "answers" } = $props();
  let away = $state(false);
  $effect(() => {
    if (view.phase !== "offline") return void (away = false);
    const timer = setTimeout(() => (away = true), 800);
    return () => clearTimeout(timer);
  });
  const then = $derived(
    kind === "reads" ? ""
    : kind === "answers" ? tr("Je antwoord komt pas bij de agent aan als je Mac verbonden is.", "Your answer only reaches the agent once your Mac is connected.")
    : writingWaits(view) ? tr("Wat je verstuurt is nog niet verzonden: het wacht op deze telefoon en gaat zodra je Mac terug is.", "What you send is not sent yet: it waits on this phone and goes as soon as your Mac is back.")
    : tr("Je kunt versturen zodra je Mac verbonden is.", "You can send once your Mac is connected."),
  );
</script>

{#if away}
  <div class="strip"><Banner icon="wifi-off">{offlineWords(view)}{then ? " " + then : ""}</Banner></div>
{/if}

<style>
  .strip { margin-bottom: 8px; animation: in 250ms ease-out; }
  @keyframes in { from { opacity: 0; } }
</style>
