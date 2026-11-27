// The machines a session can run on over SSH (`RemoteMachines` on the Mac; `nook_core::workspace::remote`): saved in
// Settings › Devices › Machines, picked under the composer ("Runs on"). Pure helpers here, so they are tested apart.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/** How often "Automatic" picks a place (`BalanceLevel`). */
export type BalanceLevel = "prefer" | "normal" | "lessOften" | "manualOnly";
export const balanceLevels: BalanceLevel[] = ["prefer", "normal", "lessOften", "manualOnly"];

export interface RemoteMachine {
  id: string;
  name: string;
  host: string;
  port?: number | null;
  identityFile?: string | null;
  lastUsedAt?: string | null;
  balance?: BalanceLevel | null;
  /** Project path on this computer → its folder on the machine: the projects shared with it. */
  projectFolders?: Record<string, string>;
  /** Logs in with a password, which Nook asks for once per run (or keeps in the system's secret store). */
  passwordLogin?: boolean;
}

/** Whether Nook has a password machine's password now, and whether it is kept in the secret store. */
export interface PasswordState {
  unlocked: boolean;
  kept: boolean;
}

/** A machine this computer probably reaches, found in `~/.ssh/config`, `known_hosts` or the tailnet. */
export interface MachineSuggestion {
  name: string;
  host: string;
  port: number | null;
  source: "sshConfig" | "knownHosts" | "tailscale";
  detail: string | null;
}

export interface PickedPlace {
  machineId: string;
  name: string;
  folder: string;
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
  save: (m: { id?: string | null; name: string; host: string; port?: number | null; identityFile?: string | null; passwordLogin?: boolean | null }) =>
    invoke<RemoteMachine>("machines_save", { id: m.id ?? null, name: m.name, host: m.host, port: m.port ?? null, identityFile: m.identityFile ?? null, passwordLogin: m.passwordLogin ?? null }),
  passwords: () => invoke<Record<string, PasswordState>>("machines_passwords"),
  /** Logs in once with the password before Nook keeps it; a password that does not get in is forgotten. */
  unlock: (id: string, password: string, keep: boolean) => invoke<MachineCheck>("machines_unlock", { id, password, keep }),
  lock: (id: string) => invoke<void>("machines_lock", { id }),
  remove: (id: string) => invoke<void>("machines_remove", { id }),
  test: (id: string) => invoke<MachineCheck>("machines_test", { id }),
  onChanged: (f: () => void): Promise<UnlistenFn> => listen("machines-changed", () => f()),
  discover: () => invoke<MachineSuggestion[]>("machines_discover"),
  setBalance: (id: string, level: BalanceLevel) => invoke<void>("machines_set_balance", { id, level }),
  localBalance: () => invoke<BalanceLevel>("machines_local_balance"),
  setLocalBalance: (level: BalanceLevel) => invoke<void>("machines_set_local_balance", { level }),
  shareProject: (id: string, project: string, folder: string) => invoke<void>("machines_share_project", { id, project, folder }),
  forgetProject: (id: string, project: string) => invoke<void>("machines_forget_project", { id, project }),
  /** Where "Automatic" starts it: a machine the project is shared with, or null for this computer. */
  pick: (project: string, provider: string, localAvailable: boolean) =>
    invoke<PickedPlace | null>("machines_pick", { project, provider, localAvailable }),
};

/** A project path as a key, as the core keeps it (`project_key`): trimmed, without a trailing separator. */
export function projectKey(project: string): string {
  const t = project.trim();
  const stripped = t.replace(/[\\/]+$/, "");
  return stripped || t;
}

/** The project's folder on the machine, when a session of it ran there. */
export function folderFor(machine: RemoteMachine, project: string): string | null {
  const key = projectKey(project);
  const folder = key ? machine.projectFolders?.[key] : undefined;
  return folder && folder.trim() ? folder : null;
}

/** The machines "Automatic" may pick for a project: shared with it, and not set to Manual only. */
export function sharedMachines(machines: RemoteMachine[], project: string): RemoteMachine[] {
  return machines.filter((m) => folderFor(m, project) !== null && (m.balance ?? "normal") !== "manualOnly");
}

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
