// Settings › Maintenance: the calls to the Rust side (`commands/maintenance.rs`) and the links Nook keeps.
import { invoke } from "@tauri-apps/api/core";
import type { Settings } from "./types";

export interface MaintenanceInfo {
  dataFolder: string;
  cacheBytes: number;
  version: string;
  tauriVersion: string;
  webviewVersion: string | null;
  os: string;
  arch: string;
}

export const maintenance = {
  info: () => invoke<MaintenanceInfo>("maintenance_info"),
  openDataFolder: () => invoke<string>("open_data_folder"),
  clearCaches: () => invoke<number>("clear_caches"),
  /// Asks where to save; `null` when cancelled.
  exportSettings: () => invoke<string | null>("export_settings"),
  resetSettings: () => invoke<Settings>("reset_settings"),
};

export const REPOSITORY = "https://github.com/IAMichan/nook";
export const LINKS = {
  source: REPOSITORY,
  releases: `${REPOSITORY}/releases`,
  changes: `${REPOSITORY}/blob/main/CHANGELOG.md`,
  report: `${REPOSITORY}/issues/new`,
  license: `${REPOSITORY}/blob/main/LICENSE`,
  notices: `${REPOSITORY}/blob/main/THIRD-PARTY-NOTICES.md`,
};

/// A size for people: "0 KB", "340 KB", "12.4 MB".
export function readableSize(bytes: number): string {
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}
