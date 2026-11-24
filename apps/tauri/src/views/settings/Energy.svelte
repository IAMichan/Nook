<script lang="ts">
  // Energy on System (the Mac's `energySection`): how much Nook does by itself on battery or a hot or busy computer, as
  // one segmented choice with its explanation behind the ⓘ, what the choice means, and what Nook does right now.
  import Segmented from "./Segmented.svelte";
  import InfoLabel from "./InfoLabel.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { nook } from "../../lib/state.svelte";
  import { services, serviceEvents, type EnergyView } from "../../lib/services";
  import type { EnergyMode } from "../../lib/types";
  import { tr } from "../../lib/i18n.svelte";

  const s = $derived(nook.settings!);
  const energyModes: { id: EnergyMode; title: string; detail: string }[] = $derived([
    { id: "automatic", title: tr("Automatisch", "Automatic"), detail: tr("Nook doet een stap terug op de accu, als je computer warm of druk bezig is, en als je weg bent.", "Nook steps back on battery, when your computer is hot or busy, and when you are away.") },
    { id: "saver", title: tr("Zuinig", "Saver"), detail: tr("Altijd licht: het scherm wordt minder vaak gelezen en suggesties komen minder vaak. Fijn op een laptop die lang op de accu moet.", "Always light: the screen is read less often and suggestions come less often. Good for a laptop that has to last on battery.") },
    { id: "full", title: tr("Volle kracht", "Full power"), detail: tr("Nooit rustiger voor de accu of een drukke computer. Een warme computer krijgt nog wel even rust.", "Never slows down for the battery or a busy computer. A hot computer still gets a break.") },
  ]);
  let energy = $state<EnergyView | null>(null);
  $effect(() => {
    services.energyStatus().then((v) => (energy = v)).catch(() => {});
    const un = serviceEvents.onEnergy((v) => (energy = v));
    return () => {
      un.then((f) => f());
    };
  });
  const pace = $derived(energy?.plan.pace ?? "full");
</script>

{#if nook.info?.capabilities.desktop}
  <h3>{tr("Energie", "Energy")}</h3>
  <div class="group">
    <div class="row">
      <InfoLabel label={tr("Werk op de achtergrond", "Background work")}
        info={`${tr("Scherm lezen, meedenken en meetings herkennen terwijl jij werkt. Wat je zelf vraagt gaat altijd op volle snelheid.", "Reading the screen, thinking along and spotting meetings while you work. Anything you ask for always runs at full speed.")} ${tr("Nook werkt op de achtergrond zodat een antwoord direct klaar is: hij leest de tekst op je scherm, denkt mee en kijkt of je in een meeting zit. Dat kost een beetje stroom. Als Nook een stap terugdoet, leest een vraag het scherm alsnog meteen.", "Nook works in the background so an answer is ready right away: it reads the text on your screen, thinks along and checks whether you are in a meeting. That costs a little power. When Nook steps back, a question still reads the screen right away.")}`} />
      <Segmented label={tr("Werk op de achtergrond", "Background work")} value={s.energyMode} options={energyModes.map((m) => ({ value: m.id, label: m.title }))} onchange={(mode) => nook.saveSettings({ energyMode: mode })} />
    </div>
    <p class="note">{energyModes.find((m) => m.id === s.energyMode)?.detail}</p>
    <div class="row">
      <span>{tr("Nu", "Right now")}</span>
      <span class="now"><span class="glyph" class:light={pace !== "full"}><Ico name={pace === "full" ? "zap" : pace === "paused" ? "circle-pause" : "leaf"} size={15} /></span>{energy?.status ?? tr("Volle snelheid", "Full speed")}</span>
    </div>
  </div>
{/if}

<style>
  .now { display: inline-flex; align-items: center; gap: var(--space-6); color: var(--text2); }
  .glyph { display: inline-grid; color: var(--mint); }
  .glyph.light { color: var(--amber); }
</style>
