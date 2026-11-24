// The cheat sheet's names in the interface language (`keys.command.*` and `cheatsheet.group.*` on the Mac), shared by
// the overlay (`CheatSheet.svelte`, Ctrl+/) and Settings › Shortcuts, so both say the same.
import { tr } from "./i18n.svelte";
import type { SheetEntry, SheetGroup } from "./shortcut-sheet";

export function sheetGroupName(group: SheetGroup): string {
  switch (group) {
    case "navigation": return tr("Zoeken en navigeren", "Search and navigation");
    case "session": return tr("Gesprekken", "Conversations");
    case "composer": return tr("Schrijven", "Writing");
    case "other": return tr("Meer", "More");
  }
}

export function sheetEntryName(entry: SheetEntry): string {
  const names: Record<string, string> = {
    "Command palette": tr("Opdrachtenpalet", "Command palette"),
    "Search conversations, or settings in Settings": tr("Zoek in gesprekken, of in Instellingen naar een instelling", "Search conversations, or settings in Settings"),
    "Go to a page in the sidebar": tr("Naar een pagina in de zijbalk", "Go to a page in the sidebar"),
    "Open Settings": tr("Instellingen openen", "Open Settings"),
    "Search settings": tr("Zoek in de instellingen", "Search settings"),
    "Keyboard shortcuts": tr("Sneltoetsen", "Keyboard shortcuts"),
    "Next area of the window (Shift+F6: previous)": tr("Volgend deel van het venster (Shift+F6: vorig)", "Next area of the window (Shift+F6: previous)"),
    "New Nook": tr("Nieuwe Nook", "New Nook"),
    "Stop the answer": tr("Stop het antwoord", "Stop the answer"),
    "Show or hide the conversations": tr("Gesprekken tonen of verbergen", "Show or hide the conversations"),
    "Back to the Nook or session you had open": tr("Terug naar de Nook of sessie die je open had", "Back to the Nook or session you had open"),
    "Forward again": tr("Weer vooruit", "Forward again"),
    "Send": tr("Versturen", "Send"),
    "New line": tr("Nieuwe regel", "New line"),
    "Earlier questions": tr("Eerdere vragen", "Earlier questions"),
    "Stop the answer while it is being written": tr("Stop het antwoord terwijl het geschreven wordt", "Stop the answer while it is being written"),
    "Run the plan that waits for you": tr("Voer het plan uit dat op je wacht", "Run the plan that waits for you"),
    "Close a dialog or the palette": tr("Sluit een venster of het palet", "Close a dialog or the palette"),
  };
  return names[entry.name] ?? entry.name;
}
