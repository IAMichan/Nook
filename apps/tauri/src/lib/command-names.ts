// The names of the main window's key commands (`keys.command.*` on the Mac), for the cheat sheet and Settings ›
// Shortcuts, and their group (`ShortcutCheatSheet.group`).
import { tr } from "./i18n.svelte";

export type CommandGroup = "composer" | "navigation" | "session" | "panels" | "other";
export const COMMAND_GROUPS: CommandGroup[] = ["composer", "navigation", "session", "panels", "other"];

/// The group of a command, by the part before its first dot, as on the Mac.
export function commandGroup(command: string): CommandGroup {
  const head = command.split(".")[0];
  if (["composer", "queue", "selection", "effort", "effortPicker", "permissionPicker", "modelPicker"].includes(head)) return "composer";
  if (["search", "commandPalette", "chat", "focus", "shortcuts", "settings"].includes(head)) return "navigation";
  if (head === "session") return "session";
  if (["sidebar", "sidePanel", "sessionPanel", "terminal", "panel", "tab", "diff"].includes(head)) return "panels";
  return "other";
}

export function commandGroupName(group: CommandGroup): string {
  switch (group) {
    case "composer": return tr("Schrijven", "Writing");
    case "navigation": return tr("Zoeken en navigeren", "Search and navigation");
    case "session": return tr("Sessies", "Sessions");
    case "panels": return tr("Panelen en terminals", "Panels and terminals");
    case "other": return tr("Meer", "More");
  }
}

/// A command's name; the numbered jumps share one ("tab.jump").
export function commandName(command: string): string {
  const id = /^tab\.jump[1-9]$/.test(command) ? "tab.jump" : command;
  const names: Record<string, string> = {
    "composer.send": tr("Bericht versturen", "Send message"),
    "composer.newline": tr("Nieuwe regel", "New line"),
    "composer.stash": tr("Concept opzijzetten of terughalen", "Stash or restore the draft"),
    "composer.pasteAsText": tr("Plakken als tekst", "Paste as text"),
    "composer.startInBackground": tr("Versturen en een volgende sessie beginnen", "Send and start another session"),
    "search.toggle": tr("Alles doorzoeken", "Search everything"),
    "chat.find": tr("Zoeken", "Find"),
    "shortcuts.cheatSheet": tr("Sneltoetsen tonen", "Show keyboard shortcuts"),
    "settings.open": tr("Instellingen openen", "Open Settings"),
    "focus.next": tr("Toetsenbord naar het volgende deel", "Keyboard to the next part"),
    "focus.previous": tr("Toetsenbord naar het vorige deel", "Keyboard to the previous part"),
    "session.new": tr("Nieuwe sessie", "New session"),
    "session.interrupt": tr("Beurt onderbreken", "Interrupt the turn"),
    "session.back": tr("Terug naar de vorige sessie", "Back to the previous session"),
    "session.forward": tr("Vooruit naar de volgende sessie", "Forward to the next session"),
    "session.previous": tr("Vorige sessie", "Previous session"),
    "session.next": tr("Volgende sessie", "Next session"),
    "session.pin": tr("Sessie vastzetten", "Pin session"),
    "session.rename": tr("Sessie hernoemen", "Rename the session"),
    "session.settle": tr("Sessie afhandelen", "Settle session"),
    "session.undo": tr("Laatste lijstactie ongedaan maken", "Undo the last list action"),
    "session.copyReference": tr("Map en branch van de sessie kopiëren", "Copy the session's folder and branch"),
    "session.openInEditor": tr("Map van de sessie openen in je editor", "Open the session's folder in your editor"),
    "sidebar.toggle": tr("Zijbalk tonen of verbergen", "Show or hide the sidebar"),
    "terminal.toggle": tr("Terminal tonen of verbergen", "Show or hide the terminal"),
    "diff.toggle": tr("Wijzigingen tonen of verbergen", "Show or hide changes"),
    "panel.reopenClosed": tr("Gesloten tabblad heropenen", "Reopen closed tab"),
    "tab.close": tr("Tabblad of terminal sluiten", "Close the tab or terminal"),
    "tab.jump": tr("Naar een tab in de zijbalk (1–9)", "Go to a tab in the sidebar (1–9)"),
    "modelPicker.toggle": tr("Model kiezen", "Choose model"),
    "effortPicker.toggle": tr("Inspanning kiezen", "Choose effort"),
    "permissionPicker.toggle": tr("Toegang kiezen", "Choose access"),
    "selection.ask": tr("Vragen over de selectie", "Ask about the selection"),
    "selection.quote": tr("Selectie citeren in je bericht", "Quote the selection in your message"),
  };
  return names[id] ?? command;
}
