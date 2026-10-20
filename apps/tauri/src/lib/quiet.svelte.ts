// Meetings, screen sharing and the energy plan in the interface: whether Nook keeps quiet right now (no sounds, no
// cards that pop up by themselves) and whether he takes it easy (the idle animation rests). Every window has its own
// copy; the truth is in Rust and arrives through events.
import { services, serviceEvents, type EnergyPace, type QuietState } from "./services";

class QuietStore {
  state = $state<QuietState | null>(null);
  pace = $state<EnergyPace>("full");
  silent = $derived(this.state?.silent ?? false);
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    serviceEvents.onQuiet((s) => (this.state = s)).catch(() => {});
    serviceEvents.onEnergy((v) => this.setPace(v.plan.pace)).catch(() => {});
    services.quietStatus(false).then((v) => (this.state ??= v.state)).catch(() => {});
    services.energyStatus().then((v) => this.setPace(v.plan.pace)).catch(() => {});
  }

  private setPace(pace: EnergyPace) {
    this.pace = pace;
    // Taking it easy, Nook's idle animation rests: a webview that keeps animating keeps the GPU awake.
    document.body.classList.toggle("easy", pace !== "full");
  }
}

export const quiet = new QuietStore();
