// Moving from Beeper Desktop (`BeeperImport`, `BeeperImporter`, `BeeperImportSection` on the Mac, CH-20):
// Tauri IPC wrappers plus pure helpers for formatting status, problem messages, per-app descriptions, and the
// final check step.
import { invoke } from "@tauri-apps/api/core";
import { tr } from "./i18n.svelte";
import type { SetupCheckState } from "../components/ui/setup-check";

export interface BeeperAccount {
  id: string;
  app: string;
  name: string;
}

export type BeeperProblem =
  | { kind: "unreachable" }
  | { kind: "unauthorized" }
  | { kind: "failed"; detail: string };

export interface ImportedSummary {
  chats: number;
  settings: number;
}

export interface BeeperImportStatus {
  offered: boolean;
  done: boolean;
  hasToken: boolean;
  busy: boolean;
  installed: boolean;
  problem: BeeperProblem | null;
  accounts: BeeperAccount[];
  apps: string[];
  imported: ImportedSummary | null;
  waitingSettings: number;
}

export interface BeeperAppMeta {
  name: string;
  domain: string | null;
}

/** Apps Nook links directly (WhatsApp gateway + chat helper `chatd::APPS`). */
export const LINKABLE_CHAT_APPS = new Set([
  "whatsapp",
  "telegram",
  "signal",
  "messenger",
  "instagram",
  "x",
  "linkedin",
  "slack",
]);

const APP_META: Record<string, BeeperAppMeta> = {
  whatsapp: { name: "WhatsApp", domain: "whatsapp.com" },
  telegram: { name: "Telegram", domain: "telegram.org" },
  signal: { name: "Signal", domain: "signal.org" },
  slack: { name: "Slack", domain: "slack.com" },
  teams: { name: "Teams", domain: "teams.microsoft.com" },
  discord: { name: "Discord", domain: "discord.com" },
  messenger: { name: "Messenger", domain: "messenger.com" },
  instagram: { name: "Instagram", domain: "instagram.com" },
  linkedin: { name: "LinkedIn", domain: "linkedin.com" },
  x: { name: "X", domain: "x.com" },
  googlechat: { name: "Google Chat", domain: "chat.google.com" },
  messages: { name: "Messages", domain: null },
};

export function beeperAppMeta(app: string): BeeperAppMeta {
  return APP_META[app.toLowerCase()] ?? { name: app, domain: null };
}

export function beeperLinkable(app: string): boolean {
  return LINKABLE_CHAT_APPS.has(app.toLowerCase());
}

export function beeperProblemText(problem: BeeperProblem): string {
  switch (problem.kind) {
    case "unreachable":
      return tr(
        "Beeper Desktop antwoordt niet op deze computer. Open het en zet de Desktop API aan in Instellingen › Developers.",
        "Beeper Desktop does not answer on this computer. Open it and turn on the Desktop API in Settings › Developers.",
      );
    case "unauthorized":
      return tr(
        "Beeper accepteerde dit token niet. Maak een nieuw in Beeper Desktop › Instellingen › Developers.",
        "Beeper did not accept this token. Create a new one in Beeper Desktop › Settings › Developers.",
      );
    case "failed":
      return tr(
        "Beeper kon niet gelezen worden: {detail}",
        "Beeper could not be read: {detail}",
        { detail: problem.detail },
      );
  }
}

export function beeperSummaryText(imported: ImportedSummary): string {
  if (imported.settings > 0) {
    return tr(
      "{chats} chats kwamen mee met hun geschiedenis; {settings} vastgezette, gedempte of gearchiveerde chats volgen zodra hun app hieronder gekoppeld is.",
      "{chats} chats came over with their history; {settings} pinned, muted or archived chats follow once their app is linked below.",
      { chats: imported.chats, settings: imported.settings },
    );
  }
  return tr(
    "{chats} chats kwamen mee met hun geschiedenis. Koppel hieronder elke app om ze bij te houden.",
    "{chats} chats came over with their history. Link each app below to keep them up to date.",
    { chats: imported.chats },
  );
}

export function beeperAppDetail(app: string, accounts: BeeperAccount[], linked: boolean): string {
  if (linked) {
    return tr("Gekoppeld in Nook", "Linked in Nook");
  }
  if (!beeperLinkable(app)) {
    return tr(
      "Nook kan deze app nog niet zelf koppelen: de chats komen binnen via hun meldingen",
      "Nook cannot link this app itself yet: its chats come in through their notifications",
    );
  }
  const names = accounts
    .filter((a) => a.app === app)
    .map((a) => a.name.trim())
    .filter((n) => n.length > 0);
  if (names.length === 0) {
    return tr("Koppel hem nog één keer in Nook", "Link it once more in Nook");
  }
  return tr(
    "In Beeper als {names} · koppel hem nog één keer in Nook",
    "In Beeper as {names} · link it once more in Nook",
    { names: names.join(", ") },
  );
}

export function beeperCheckState(
  status: Pick<BeeperImportStatus, "imported" | "busy" | "apps">,
  isLinked: (app: string) => boolean,
): SetupCheckState {
  if (!status.imported) {
    return status.busy ? { kind: "checking" } : { kind: "idle" };
  }
  if (status.apps.length === 0) {
    return { kind: "passed", message: beeperSummaryText(status.imported) };
  }
  const linked = status.apps.filter((app) => isLinked(app)).length;
  return {
    kind: "passed",
    message: tr(
      "{linked} van {total} apps uit Beeper zijn gekoppeld in Nook.",
      "{linked} of {total} apps from Beeper are linked in Nook.",
      { linked, total: status.apps.length },
    ),
  };
}

export const beeperImportApi = {
  status: () => invoke<BeeperImportStatus>("beeper_import_status"),
  saveToken: (token: string) => invoke<BeeperImportStatus>("beeper_import_save_token", { token }),
  run: () => invoke<BeeperImportStatus>("beeper_import_run"),
  finish: () => invoke<BeeperImportStatus>("beeper_import_finish"),
  openApp: () => invoke<void>("beeper_import_open_app"),
};
