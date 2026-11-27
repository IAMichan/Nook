// Pure types and formatting helpers for read-only guest session links (`GuestShares` / `GuestStrip` on macOS, AG-81).

export interface HeldGuestMessage {
  id: string;
  text: string;
  files: string[];
  received: string;
}

export interface GuestShareInfo {
  until: string;
  link: string;
  watching: number;
  held: HeldGuestMessage[];
}

export interface GuestSharesSnapshot {
  canShare: boolean;
  shares: Record<string, GuestShareInfo>;
}

/// Formats an ISO-8601 expiry timestamp as a short local clock time (e.g. `14:30`).
export function formatGuestUntil(iso: string, locale: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
}

/// Extracts just the filename from a saved attachment path (supports both `/` and `\` separators).
export function fileBaseName(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const parts = trimmed.split(/[\\/]/);
  return parts[parts.length - 1] || path;
}

/// Comma-separated basenames for files attached to a held guest message.
export function guestFileNames(files: string[]): string {
  return files.map(fileBaseName).join(", ");
}

/// Selects the status copy key and vars for `GuestStrip` matching `GuestStrip.status(_:)` on macOS.
export function guestStatusKey(watching: number): "none" | "one" | "many" {
  if (watching <= 0) return "none";
  if (watching === 1) return "one";
  return "many";
}
