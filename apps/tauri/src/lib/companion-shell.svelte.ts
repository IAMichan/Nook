// On Android a paired phone opens as the iPhone app does: the companion is the whole app (the computer's tabs along the
// bottom). Nook on the phone itself (its own brain) stays a tap away in the companion's Settings, and is the app again
// while no computer is paired.
const LOCAL_KEY = "companion.local";

function readLocal(): boolean {
  try {
    return localStorage.getItem(LOCAL_KEY) === "1";
  } catch {
    return false;
  }
}

export const shell = $state({
  /** A computer is paired (connected or looked for). */
  paired: false,
  /** The user chose Nook on this phone over the companion. */
  local: readLocal(),
  /** Text another app shared with Nook, waiting for the companion to offer where it goes. */
  shared: null as string | null,
});

export function setLocal(local: boolean) {
  shell.local = local;
  try {
    localStorage.setItem(LOCAL_KEY, local ? "1" : "0");
  } catch {
    // Remembered for this visit only.
  }
}

/** Whether the companion is the whole app: on Android, paired, and not switched to Nook on the phone. */
export function companionHome(android: boolean): boolean {
  return android && shell.paired && !shell.local;
}
