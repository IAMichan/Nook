import { describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }));

import { bubbleText, context, fileLabel, initials, settingsChats, ticks } from "./whatsapp";
import type { WhatsAppMessage, WhatsAppSettingsChat } from "./connectors";

const message = (patch: Partial<WhatsAppMessage>): WhatsAppMessage => ({
  id: "1", chat: "c", senderName: "", text: "", media: { kind: "none" }, date: "2026-10-20T12:00:00Z", fromMe: false, ...patch,
});

describe("WhatsApp-kaart", () => {
  it("noemt bestanden zoals de Mac", () => {
    expect(fileLabel({ kind: "document", name: "offerte.pdf" })).toBe("offerte.pdf");
    expect(fileLabel({ kind: "document", name: null })).toBe("Document");
    expect(fileLabel({ kind: "image" })).toBe("Foto");
    expect(fileLabel({ kind: "voice" })).toBe("Spraakbericht");
    expect(fileLabel({ kind: "location" })).toBeNull();
  });

  it("zegt wat een sticker of locatie is, naast de tekst", () => {
    expect(bubbleText(message({ text: "hoi" }))).toBe("hoi");
    expect(bubbleText(message({ media: { kind: "location" } }))).toBe("Locatie");
    expect(bubbleText(message({ media: { kind: "image" }, text: "kijk" }))).toBe("kijk");
  });

  it("toont de vinkjes van WhatsApp", () => {
    expect(ticks("sent")?.symbol).toBe("✓");
    expect(ticks("read")).toEqual({ symbol: "✓✓", title: "Gelezen", tone: "read" });
    expect(ticks("failed")?.title).toBe("Niet verzonden");
    expect(ticks(null)).toBeNull();
  });

  it("telt nieuwe berichten pas vanaf twee", () => {
    expect(context(1)).toBe("WhatsApp");
    expect(context(3)).toBe("WhatsApp · 3 nieuw");
  });

  it("zoekt chats per naam en houdt verborgen chats apart", () => {
    const all: WhatsAppSettingsChat[] = [
      { jid: "a", name: "Lisa", kind: "person", mode: "automatic", hidden: false },
      { jid: "b", name: "Familie", kind: "group", mode: "loud", hidden: false },
      { jid: "c", name: "Spam", kind: "person", mode: "automatic", hidden: true },
    ];
    expect(settingsChats(all, "fam").shown.map((c) => c.jid)).toEqual(["b"]);
    expect(settingsChats(all, "").shown.length).toBe(2);
    expect(settingsChats(all, "").hidden.map((c) => c.jid)).toEqual(["c"]);
    expect(initials("Lisa de Vries")).toBe("LV");
    expect(initials("Jan")).toBe("JA");
  });
});
