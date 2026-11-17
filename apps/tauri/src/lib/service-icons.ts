// Shared domain icon cache (`service_icon` IPC) and compact 12px fallback glyphs for inline citation pills.
import { connectorsApi } from "./connectors";

const iconCache = new Map<string, Promise<string | null>>();

export function serviceIconUrl(domain: string | null | undefined): Promise<string | null> {
  const d = domain?.trim();
  if (!d) return Promise.resolve(null);
  let pending = iconCache.get(d);
  if (!pending) {
    pending = connectorsApi.serviceIcon(d).catch(() => null);
    iconCache.set(d, pending);
  }
  return pending;
}

/** Small 12x12 SVG icon for a source id when no website favicon is used (or before it loads). */
export function sourceGlyphSvg(sourceId: string | null | undefined): string {
  const path = (() => {
    switch (sourceId) {
      case "mail":
      case "resend":
        return '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>';
      case "calendar":
      case "icalfeeds":
      case "calcom":
        return '<rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 10h18"/>';
      case "whatsapp":
      case "messages":
        return '<path d="M20 11.5a8 8 0 0 1-8 8H5l-3 2v-10a9 9 0 0 1 18 0Z"/>';
      case "screen":
      case "browser":
      case "terminal":
        return '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 20h8M12 17v3"/>';
      case "web":
        return '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>';
      case "github":
      case "gitlab":
        return '<path d="m8 9-4 3 4 3M16 9l4 3-4 3M13.5 7l-3 10"/>';
      case "files":
      case "notes":
      case "bear":
      case "notion":
      case "callnotes":
        return '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9Z"/><path d="M14 3v6h6"/>';
      case "loops":
      case "reminders":
      case "things":
        return '<path d="M9 11l3 3L20 6"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>';
      case "memory":
        return '<path d="M12 3l1.8 4.8L18.5 9l-4.7 1.8L12 15.5l-1.8-4.7L5.5 9l4.7-1.2Z"/>';
      default:
        return '<circle cx="12" cy="12" r="7"/><path d="M12 8v4l3 2"/>';
    }
  })();
  return `<svg class="cite-svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${path}</svg>`;
}
