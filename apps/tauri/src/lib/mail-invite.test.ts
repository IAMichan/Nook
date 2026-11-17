import { describe, expect, test } from "vitest";
import { hasInviteFile, inviteSummary } from "./mail-invite";

describe("mail-invite", () => {
  test("formats title and start-end clock", () => {
    const line = inviteSummary(
      {
        title: "Lunch",
        start: "2026-11-17T12:30:00Z",
        end: "2026-11-17T13:30:00Z",
      },
      "en-GB",
    );
    expect(line).toContain("Lunch · ");
    expect(line).toContain("–");
  });

  test("falls back to title on invalid start", () => {
    expect(inviteSummary({ title: "Lunch", start: "not-a-date", end: "" }, "en-GB")).toBe("Lunch");
  });

  test("detects invite.ics attachment", () => {
    expect(hasInviteFile({ attachments: ["/tmp/nook-invites/1/invite.ics"] })).toBe(true);
    expect(hasInviteFile({ attachments: ["C:\\temp\\nook-invites\\1\\invite.ics"] })).toBe(true);
    expect(hasInviteFile({ attachments: [] })).toBe(false);
    expect(hasInviteFile({})).toBe(false);
  });
});
