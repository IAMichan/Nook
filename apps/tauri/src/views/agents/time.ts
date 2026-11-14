import { tr } from "../../lib/i18n.svelte";

// Korte tijden voor de lijst Agents: "nu", "5 min", "3 u", "2 d".
export function ago(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "";
  const s = Math.max(0, (now - new Date(iso).getTime()) / 1000);
  if (s < 60) return tr("nu", "now");
  if (s < 3600) return tr("{n} min", "{n} min", { n: Math.floor(s / 60) });
  if (s < 86400) return tr("{n} u", "{n} h", { n: Math.floor(s / 3600) });
  return tr("{n} d", "{n} d", { n: Math.floor(s / 86400) });
}

/// "1 u 5 min", "12 min", "40 s".
export function duration(seconds: number): string {
  if (seconds < 60) return tr("{n} s", "{n} s", { n: Math.round(seconds) });
  const m = Math.floor(seconds / 60);
  if (m < 60) return tr("{n} min", "{n} min", { n: m });
  return tr("{h} u {m} min", "{h} h {m} min", { h: Math.floor(m / 60), m: m % 60 });
}

export function folderName(path: string): string {
  const name = path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "";
  return name || tr("geen map", "no folder");
}
