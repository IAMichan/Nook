// The Valorant Coach for this window (Svelte 5 runes): the latest view from Rust, and a toast when the coach has new
// advice (a warning or good news it did not show before). The main window starts it, so advice arrives on any page.
import { games, coachingText, newCoaching, type CoachView } from "./games";
import { english } from "./i18n.svelte";
import { toast } from "./toast.svelte";

class GamerStore {
  view = $state<CoachView | null>(null);
  /// Advice already shown; `null` until the first view, so opening Nook mid-match does not replay everything.
  private seen: Set<string> | null = null;
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    games.view().then((v) => this.set(v)).catch(() => {});
    games.onUpdated((v) => this.set(v));
  }

  set(view: CoachView) {
    const insights = view.analysis?.insights ?? [];
    if (this.seen && view.prefs.notify) {
      for (const insight of newCoaching(this.seen, insights).slice(0, 2)) {
        const { title, body } = coachingText(insight, english() ? "en" : "nl");
        if (insight.severity === "success") toast.success(title, body);
        else toast.warning(title, body);
      }
    }
    this.seen = new Set(insights.map((i) => i.id));
    this.view = view;
  }

  /// Runs a coach command and shows its result, or the error as a toast.
  async run(action: () => Promise<CoachView>, failed: string) {
    try {
      this.set(await action());
    } catch (e) {
      toast.error(failed, e);
    }
  }
}

export const gamer = new GamerStore();
