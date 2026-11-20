// What needs you, from every page of Settings (the Mac's `attention(problems:)` in SettingsView+General): the list at
// the top of the Overview, and its count on the Overview's row in the sidebar.
import { connectorsApi } from "../../lib/connectors";
import { tr } from "../../lib/i18n.svelte";
import { nook } from "../../lib/state.svelte";
import type { SettingsSectionId } from "../../lib/settings-pages";

export interface AttentionItem { id: string; title: string; detail: string; button: string; open: SettingsSectionId }

class Attention {
  /** Services linked; null until the first look. */
  linked = $state<number | null>(null);

  /** Looks again at what is linked (the Overview and the sidebar call it when Settings opens). */
  refresh() {
    connectorsApi.overview()
      .then((o) => (this.linked = (o.connectors ?? []).filter((c) => c.configured).length + (o.mcp ?? []).length))
      .catch(() => {});
  }

  get items(): AttentionItem[] {
    const items: AttentionItem[] = [];
    if (nook.info && !nook.info.brainReady) {
      items.push({
        id: "brain", open: "brain", button: tr("Kies", "Choose"), title: tr("Kies een brein", "Choose a brain"),
        detail: tr("Claude, een andere AI of gratis op je computer.", "Claude, another AI, or free on your computer."),
      });
    }
    if (this.linked === 0) {
      items.push({
        id: "services", open: "connections", button: tr("Bekijk", "View"), title: tr("Koppel je diensten", "Connect your services"),
        detail: tr("{count} bronnen actief. Mail, browser, GitHub, Stripe…", "{count} sources active. Mail, browser, GitHub, Stripe…", { count: 0 }),
      });
    }
    return items;
  }
}

export const attention = new Attention();
