// The machines a session can run on over SSH (`RemoteMachines` on the Mac; `nook_core::workspace::remote`): saved in
// Settings › Devices › Machines, picked under the composer ("Runs on"). Pure helpers here, so they are tested apart.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface RemoteMachine {
  id: string;
  name: string;
  host: string;
  port?: number | null;
  identityFile?: string | null;
  lastUsedAt?: string | null;
}

export interface RemoteTarget {
  machineId: string;
  name: string;
  host: string;
  port?: number | null;
  identityFile?: string | null;
  directory: string;
}

export interface MachineCheck {
  /** The agents found on the machine, as `RunProvider` ids. */
  agents: string[];
}

export const machinesApi = {
  list: () => invoke<RemoteMachine[]>("machines_list"),
  save: (m: { id?: string | null; name: string; host: string; port?: number | null; identityFile?: string | null }) =>
    invoke<RemoteMachine>("machines_save", { id: m.id ?? null, name: m.name, host: m.host, port: m.port ?? null, identityFile: m.identityFile ?? null }),
  remove: (id: string) => invoke<void>("machines_remove", { id }),
  test: (id: string) => invoke<MachineCheck>("machines_test", { id }),
  onChanged: (f: () => void): Promise<UnlistenFn> => listen("machines-changed", () => f()),
};

/** An ssh destination: an alias or user@host, never something ssh would read as an option (`is_valid_host`). */
export function isValidHost(host: string): boolean {
  const h = host.trim();
  return h.length > 0 && h.length <= 255 && !h.startsWith("-") && /^[A-Za-z0-9@.\-_:[\]]+$/.test(h);
}

/** A folder on the machine: absolute, or from its home (`~`, `~/code`) (`is_valid_directory`). */
export function isValidRemoteFolder(path: string): boolean {
  const p = path.trim();
  return p.length > 0 && !p.includes("\n") && (p.startsWith("/") || p === "~" || p.startsWith("~/"));
}

/** The name a machine gets from its address until you give it one: `me@buildbox.local` → `buildbox` (`suggested_name`). */
export function suggestedName(host: string): string {
  const bare = host.trim().split("@").pop() ?? "";
  if (!bare) return "";
  const isAddress = bare.includes(":") || bare.split(".").every((p) => /^\d+$/.test(p));
  return isAddress ? bare : (bare.split(".")[0] ?? bare);
}

/** "buildbox:app", the way the composer's heading names a folder on a machine; "…" before one is typed. */
export function machineFolderLabel(machine: Pick<RemoteMachine, "name">, folder: string): string {
  const clean = folder.trim().replace(/\/+$/, "");
  const last = clean === "~" ? "~" : (clean.split("/").pop() ?? "");
  return `${machine.name}:${last || "…"}`;
}

/** The folder last used on each machine, so the composer offers it again (kept on this computer only). */
const folderKey = (id: string) => `nook.machines.folder:${id}`;

export function rememberedFolder(id: string): string {
  try { return localStorage.getItem(folderKey(id)) ?? ""; } catch { return ""; }
}

export function rememberFolder(id: string, folder: string): void {
  try { localStorage.setItem(folderKey(id), folder.trim()); } catch { /* a convenience only */ }
}
