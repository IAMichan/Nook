// What needs you, from every page of Settings (the Mac's `attention(problems:)` in SettingsView+General): the list at
// the top of the Overview, and the counts on the sidebar's rows (the Mac's `SettingsSidebar(badges:)`): the Overview
// counts this list, Chat apps the chat apps that lost their link, Services the linked services that fail, and Typing
// one while completing is on but cannot work.
import { autocomplete, autocompleteEvents, type AutocompleteStatus } from "../../lib/autocomplete";
import { connectorsApi, health } from "../../lib/connectors";
import { tr } from "../../lib/i18n.svelte";
import { nook } from "../../lib/state.svelte";
import type { SettingsSectionId } from "../../lib/settings-pages";

export interface AttentionItem { id: string; title: string; detail: string; button: string; open: SettingsSectionId }

class Attention {
  /** Services linked; null until the first look. */
  linked = $state<number | null>(null);
  /** Linked services whose last refresh failed (the Mac's `ConnectionProblems` that are not chats). */
  serviceProblems = $state(0);
  /** Chat apps that are on but lost their link or cannot be reached. */
  chatProblems = $state(0);
  /** Completing as you type, while it is on. */
  typing = $state<AutocompleteStatus | null>(null);
  #watching = false;

  /** Looks again at what is linked (the Overview and the sidebar call it when Settings opens). */
  refresh() {
    connectorsApi.overview()
      .then((o) => {
        const connectors = o.connectors ?? [];
        this.linked = connectors.filter((c) => c.configured).length + (o.mcp ?? []).length;
        this.serviceProblems = connectors.filter((c) => !c.id.startsWith("whatsapp") && ["needsYou", "broken"].includes(health(c))).length;
      })
      .catch(() => {});
    connectorsApi.whatsapp()
      .then((w) => (this.chatProblems = w.settings.enabled && !["connected", "connecting", "needsQr"].includes(w.link.kind) ? 1 : 0))
      .catch(() => {});
    if (!nook.info?.capabilities.desktop) return;
    autocomplete.view().then((v) => (this.typing = v.status)).catch(() => {});
    if (!this.#watching) {
      this.#watching = true;
      autocompleteEvents.onStatus((st) => (this.typing = st)).catch(() => (this.#watching = false));
    }
  }

  /** The count on a page's row in the sidebar; 0 shows none. */
  badge(page: SettingsSectionId): number {
    switch (page) {
      case "start": return this.items.length;
      case "chats": return this.chatProblems;
      case "connections": return this.serviceProblems;
      case "autocomplete": return nook.settings?.autocomplete?.enabled && this.typing?.state === "noModel" ? 1 : 0;
      default: return 0;
    }
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
