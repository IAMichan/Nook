import { beforeEach, describe, expect, it } from "vitest";
import {
  beeperAppDetail,
  beeperAppMeta,
  beeperCheckState,
  beeperLinkable,
  beeperProblemText,
  beeperSummaryText,
  type BeeperAccount,
} from "./beeper-import";
import { nook } from "./state.svelte";

describe("beeper-import helpers", () => {
  beforeEach(() => {
    nook.settings = { ...(nook.settings ?? {}), appLanguage: "en" } as typeof nook.settings;
  });

  it("formats each structured Beeper API problem", () => {
    expect(beeperProblemText({ kind: "unreachable" })).toContain("Desktop API");
    expect(beeperProblemText({ kind: "unauthorized" })).toContain("token");
    expect(beeperProblemText({ kind: "failed", detail: "HTTP 502" })).toBe("Beeper could not be read: HTTP 502");
  });

  it("formats import summary with and without waiting settings", () => {
    expect(beeperSummaryText({ chats: 12, settings: 0 })).toBe(
      "12 chats came over with their history. Link each app below to keep them up to date.",
    );
    expect(beeperSummaryText({ chats: 12, settings: 4 })).toBe(
      "12 chats came over with their history; 4 pinned, muted or archived chats follow once their app is linked below.",
    );
  });

  it("describes per-app link state, Beeper account names, and non-linkable apps", () => {
    const accounts: BeeperAccount[] = [
      { id: "tg-1", app: "telegram", name: "Ada Lovelace" },
      { id: "tg-2", app: "telegram", name: "Work" },
      { id: "sl-1", app: "slack", name: "" },
    ];
    expect(beeperAppDetail("telegram", accounts, true)).toBe("Linked in Nook");
    expect(beeperAppDetail("telegram", accounts, false)).toBe(
      "In Beeper as Ada Lovelace, Work · link it once more in Nook",
    );
    expect(beeperAppDetail("slack", accounts, false)).toBe("Link it once more in Nook");
    expect(beeperAppDetail("discord", accounts, false)).toContain("notifications");
    expect(beeperLinkable("whatsapp")).toBe(true);
    expect(beeperLinkable("telegram")).toBe(true);
    expect(beeperLinkable("discord")).toBe(false);
    expect(beeperAppMeta("telegram")).toEqual({ name: "Telegram", domain: "telegram.org" });
    expect(beeperAppMeta("unknownapp")).toEqual({ name: "unknownapp", domain: null });
  });

  it("derives SetupCheckState from import status and linked apps", () => {
    expect(beeperCheckState({ imported: null, busy: false, apps: [] }, () => false)).toEqual({ kind: "idle" });
    expect(beeperCheckState({ imported: null, busy: true, apps: [] }, () => false)).toEqual({ kind: "checking" });
    expect(
      beeperCheckState({ imported: { chats: 5, settings: 0 }, busy: false, apps: [] }, () => false),
    ).toEqual({
      kind: "passed",
      message: "5 chats came over with their history. Link each app below to keep them up to date.",
    });
    expect(
      beeperCheckState(
        { imported: { chats: 5, settings: 2 }, busy: false, apps: ["whatsapp", "telegram", "signal"] },
        (app) => app === "whatsapp" || app === "signal",
      ),
    ).toEqual({
      kind: "passed",
      message: "2 of 3 apps from Beeper are linked in Nook.",
    });
  });
});
