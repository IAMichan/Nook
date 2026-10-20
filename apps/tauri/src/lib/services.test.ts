import { describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }));

import { clock, estimatedPosition, screenLine, type EnergyView, type NowPlaying } from "./services";

const song: NowPlaying = {
  app: "Spotify", title: "Nummer", artist: "Band", album: "", playing: true, artwork: null,
  position: 30, duration: 200, shuffle: false, repeat: false, volume: 50, canSeek: true,
};

describe("muziek", () => {
  it("schrijft tijden als op de Mac", () => {
    expect(clock(75)).toBe("1:15");
    expect(clock(3725)).toBe("1:02:05");
    expect(clock(-3)).toBe("0:00");
  });

  it("laat de positie doorlopen terwijl het speelt", () => {
    expect(estimatedPosition(song, 1000, 6000)).toBe(35);
    expect(estimatedPosition({ ...song, playing: false }, 1000, 6000)).toBe(30);
    expect(estimatedPosition(song, 0, 10_000_000)).toBe(200);
  });
});

describe("scherm lezen en energie", () => {
  const paused: EnergyView = { plan: { pace: "paused", reasons: ["away", "battery"] }, status: "Even gepauzeerd: je bent even weg" };
  const light: EnergyView = { plan: { pace: "light", reasons: ["battery"] }, status: "Rustig aan: je computer draait op de accu" };

  it("zegt waarom er niets gelezen wordt, ook als er nog vensters bewaard zijn", () => {
    expect(screenLine(false, ["Kladblok — plan"], null)).toBe("Uit");
    expect(screenLine(true, ["Kladblok — plan"], paused)).toBe("Gepauzeerd: je bent even weg");
    expect(screenLine(true, ["Kladblok — plan"], light)).toBe("Kladblok — plan");
    expect(screenLine(true, [], light)).toBe("niets gelezen");
  });
});
