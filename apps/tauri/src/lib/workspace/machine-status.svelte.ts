// Whether each machine over SSH answers now, and which agents it has (`MachineReachability` on the Mac): the dot beside a
// machine under "Runs on". Nothing polls: machines are asked when "Runs on" opens, and an answer counts for two minutes,
// so an idle Nook asks nothing.
import { machinesApi, type RemoteMachine } from "./machines";

export type MachineStatus =
  | { kind: "unknown" }
  | { kind: "checking" }
  | { kind: "online"; agents: string[] }
  | { kind: "offline"; message: string };

/** How long an answer counts, in milliseconds. */
export const FRESH_FOR = 120_000;

/** Whether a machine's answer from `at` should be asked again at `now`. */
export function isStale(at: number | undefined, now: number): boolean {
  return at === undefined || now - at >= FRESH_FOR;
}

class MachineStatuses {
  statuses = $state<Record<string, MachineStatus>>({});
  private checkedAt: Record<string, number> = {};
  private running = new Set<string>();

  status(id: string): MachineStatus {
    return this.statuses[id] ?? { kind: "unknown" };
  }

  /** Asks every machine whose answer is older than two minutes; the ones already asking are left alone. */
  refresh(machines: RemoteMachine[]) {
    const now = Date.now();
    for (const m of machines) {
      if (this.running.has(m.id) || !isStale(this.checkedAt[m.id], now)) continue;
      this.running.add(m.id);
      this.statuses[m.id] = { kind: "checking" };
      machinesApi
        .test(m.id)
        .then((r) => (this.statuses[m.id] = { kind: "online", agents: r.agents }))
        .catch((e) => (this.statuses[m.id] = { kind: "offline", message: String(e) }))
        .finally(() => {
          this.checkedAt[m.id] = Date.now();
          this.running.delete(m.id);
        });
    }
  }
}

export const machineStatuses = new MachineStatuses();
