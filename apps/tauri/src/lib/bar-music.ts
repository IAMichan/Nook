// The closed bar and music (the notch's `NowPlayingStrip` on the Mac): a new track shows its title under the round
// Nook for a few seconds, and while music plays the round Nook carries a small equalizer. Pure, for tests.
import type { NowPlaying } from "./services";

/// How long the new-track strip stays.
export const TRACK_STRIP_MS = 6000;

/// The track on one line: "Title – Artist".
export function trackLine(n: Pick<NowPlaying, "title" | "artist"> | null): string | null {
  if (!n?.title?.trim()) return null;
  return n.artist?.trim() ? `${n.title} – ${n.artist}` : n.title;
}

/// Whether `next` is another track than `previous` and plays: the moment for the strip. The first track Nook sees
/// (at start) and a paused one say nothing.
export function isNewTrack(previous: string | null | undefined, next: NowPlaying | null): boolean {
  const line = trackLine(next);
  return !!line && !!next?.playing && previous !== undefined && previous !== line;
}

export type OrbMood = "idle" | "working" | "waiting" | "listen";
export interface MoodInputs { nookWaiting: number; nookWorking: number; agentsWaiting: number; agentsRunning: number; playing: boolean }

/// Nook's mood (the Mac's `NookMood` per tab): closed, everything that waits or works; open, what the tab on screen is
/// about (the agents on Agents, the music on Music, the Nooks on Nook), so the orb answers the page you look at.
export function orbMood(tab: string | null, m: MoodInputs): OrbMood {
  const nook: OrbMood = m.nookWaiting ? "waiting" : m.nookWorking ? "working" : "idle";
  const agentsMood: OrbMood = m.agentsWaiting ? "waiting" : m.agentsRunning ? "working" : "idle";
  switch (tab) {
    case "agents": return agentsMood;
    case "music": return m.playing ? "listen" : "idle";
    case "nook": return nook;
    default: return nook !== "idle" ? (nook === "waiting" || agentsMood !== "waiting" ? nook : agentsMood) : agentsMood;
  }
}
