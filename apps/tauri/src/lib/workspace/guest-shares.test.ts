import { describe, expect, it } from "vitest";
import { fileBaseName, formatGuestUntil, guestFileNames, guestStatusKey } from "./guest-shares";

describe("guest-shares helpers", () => {
  it("extracts basenames for both Windows and POSIX paths", () => {
    expect(fileBaseName("/Users/test/guest-files/abc/screenshot.png")).toBe("screenshot.png");
    expect(fileBaseName("C:\\Users\\test\\AppData\\Roaming\\Nook\\guest-files\\photo.webp")).toBe("photo.webp");
    expect(fileBaseName("notes.txt")).toBe("notes.txt");
    expect(fileBaseName("/trailing/slash/")).toBe("slash");
  });

  it("joins attachment filenames with commas", () => {
    expect(guestFileNames(["/tmp/a/one.png", "C:\\tmp\\b\\two.jpg"])).toBe("one.png, two.jpg");
    expect(guestFileNames([])).toBe("");
  });

  it("picks the right viewer pluralization bucket", () => {
    expect(guestStatusKey(0)).toBe("none");
    expect(guestStatusKey(-1)).toBe("none");
    expect(guestStatusKey(1)).toBe("one");
    expect(guestStatusKey(2)).toBe("many");
    expect(guestStatusKey(9)).toBe("many");
  });

  it("formats valid ISO timestamps and returns empty string on invalid dates", () => {
    const formatted = formatGuestUntil("2026-11-27T14:30:00.000Z", "en-GB");
    expect(formatted).toMatch(/\d{2}:\d{2}/);
    expect(formatGuestUntil("not-a-date", "en-GB")).toBe("");
  });
});
