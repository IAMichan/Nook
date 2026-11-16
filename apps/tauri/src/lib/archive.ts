// Settings › Agents › Archive (`ArchiveSettingsSection` and `ArchivePurge` on the Mac): what is archived, narrowed by a
// search, newest first; and which of it may go in "Delete all archived…" (never something that still works).
import { matchesSearch } from "./shell-routes";

export function shownArchived<T>(items: T[], query: string, archived: (t: T) => boolean, fields: (t: T) => string[], updated: (t: T) => string): T[] {
  return items
    .filter((t) => archived(t) && matchesSearch(query, ...fields(t)))
    .sort((a, b) => Date.parse(updated(b)) - Date.parse(updated(a)));
}

export function deletable<T>(items: T[], busy: (t: T) => boolean): T[] {
  return items.filter((t) => !busy(t));
}

/// The last part of a path, for a session's folder ("C:\\code\\web" → "web").
export function folderName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}
