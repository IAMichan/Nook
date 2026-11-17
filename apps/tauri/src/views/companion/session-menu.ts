// The session menus of the Agents tab in the Mac's order (`ROW_MENU`, `HEADER_MENU`), as `Menu` sections: the same
// rows on a session's long press and in its header, as the iPhone's `SessionActionsMenu`.
import type { SessionDigest } from "../../lib/companion";
import { menuEntries, type MenuEntry } from "../../lib/companion-sessions";
import { tr } from "../../lib/i18n.svelte";
import type { MenuItem } from "../../components/ui/Menu.svelte";

export interface SessionMenuHandlers {
  /** An action that goes straight to the computer. */
  run: (action: string) => void;
  /** Rename, delete and end ask first. */
  ask: (kind: "rename" | "delete" | "end") => void;
  /** The moment picker for "Pick a time…". */
  pickTime: () => void;
  /** A fork, which opens the session it made. */
  fork: () => void;
}

function copy(text: string) {
  void navigator.clipboard?.writeText(text);
}

/** The rows of one entry of the layout. */
function rows(entry: MenuEntry, s: SessionDigest, offered: Set<string>, h: SessionMenuHandlers): MenuItem[] {
  switch (entry) {
    case "rename": return [{ label: tr("Hernoem", "Rename"), icon: "pencil", onselect: () => h.ask("rename") }];
    case "pin": return [{ label: tr("Vastzetten", "Pin"), icon: "pin", onselect: () => h.run("pin") }];
    case "unpin": return [{ label: tr("Losmaken", "Unpin"), icon: "pin-off", onselect: () => h.run("unpin") }];
    case "settle": return [{ label: tr("Afronden", "Settle"), icon: "circle-check", onselect: () => h.run("settle") }];
    case "reopen": return [{ label: tr("Heropenen", "Reopen"), icon: "inbox", onselect: () => h.run("reopen") }];
    case "retry": return [{ label: tr("Opnieuw proberen", "Retry"), icon: "refresh-cw", onselect: () => h.run("retry") }];
    case "fork": return [{ label: tr("Afsplitsen", "Fork"), icon: "git-branch", onselect: h.fork }];
    case "restartAgent": return [{ label: tr("Agent herstarten", "Restart agent"), icon: "refresh-cw", onselect: () => h.run("restartAgent") }];
    case "regenerateTitle": return [{ label: tr("Nieuwe titel schrijven", "Regenerate title"), icon: "sparkles", onselect: () => h.run("regenerateTitle") }];
    case "markUnread": return [{ label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => h.run("markUnread") }];
    case "mainThreadOn": return [{ label: tr("Hoofdthread maken", "Make main thread"), icon: "git-branch", onselect: () => h.run("mainThreadOn") }];
    case "mainThreadOff": return [{ label: tr("Hoofdthread uitzetten", "Stop main thread"), icon: "git-branch", onselect: () => h.run("mainThreadOff") }];
    case "archive": return [{ label: tr("Archiveer", "Archive"), icon: "archive", destructive: true, onselect: () => h.run("archive") }];
    case "delete": return [{ label: tr("Verwijder", "Delete"), icon: "trash-2", destructive: true, onselect: () => h.ask("delete") }];
    case "end": return [{ label: tr("Beëindig sessie", "End session"), icon: "circle-x", destructive: true, onselect: () => h.ask("end") }];
    case "copy": return [
      { label: tr("Kopieer pad", "Copy path"), icon: "copy", onselect: () => copy(s.path ?? s.folder) },
      ...(s.branch ? [{ label: tr("Kopieer branch", "Copy branch"), icon: "git-branch", onselect: () => copy(s.branch ?? "") }] : []),
      { label: tr("Kopieer sessie-ID", "Copy session ID"), icon: "copy", onselect: () => copy(s.id) },
    ];
    case "snooze":
      if (offered.has("unsnooze")) return [{ label: tr("Snooze opheffen", "Cancel snooze"), icon: "alarm-clock", onselect: () => h.run("unsnooze") }];
      return [
        ...(offered.has("snoozeHour") ? [{ label: tr("Een uur", "One hour"), icon: "clock", onselect: () => h.run("snoozeHour") }] : []),
        ...(offered.has("snoozeEvening") ? [{ label: tr("Vanavond", "This evening"), icon: "clock", onselect: () => h.run("snoozeEvening") }] : []),
        ...(offered.has("snoozeTomorrow") ? [{ label: tr("Morgenochtend", "Tomorrow morning"), icon: "clock", onselect: () => h.run("snoozeTomorrow") }] : []),
        ...(offered.has("snoozeLimitReset") && s.limitResetsAt ? [{ label: tr("Tot de limiet reset", "Until the limit resets"), icon: "gauge", onselect: () => h.run("snoozeLimitReset") }] : []),
        ...(offered.has("snoozeUntil") ? [{ label: tr("Kies een moment…", "Pick a time…"), icon: "calendar-clock", onselect: h.pickTime }] : []),
      ];
    default: return [];
  }
}

/** The sections of a session's menu: `layout` as far as the session offers it (`actions`, empty without `manage`). */
export function sessionMenu(layout: MenuEntry[][], s: SessionDigest, actions: string[], h: SessionMenuHandlers): MenuItem[][] {
  const offered = new Set(actions);
  return menuEntries(layout, actions).map((section) => section.flatMap((entry) => rows(entry, s, offered, h)));
}
