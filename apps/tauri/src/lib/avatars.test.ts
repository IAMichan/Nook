import { describe, expect, it } from "vitest";
import { wanted } from "./avatars.svelte";
import type { InboxChatDigest } from "./companion";

const chat = (id: string, app: string, avatar?: string): InboxChatDigest => ({ id, app, appName: app, name: id, preview: "", last: 0, unread: 0, canSend: false, waitsInApp: false, avatar });

describe("chat pictures", () => {
  it("asks only for pictures that are new or changed, and each app's icon once", () => {
    const have = { a: { version: "1" }, "app:whatsapp": { version: "" } };
    expect(wanted([chat("a", "whatsapp", "1"), chat("b", "whatsapp", "2"), chat("c", "telegram")], true, have)).toEqual(["b", "app:telegram"]);
    expect(wanted([chat("a", "whatsapp", "2")], false, have)).toEqual(["a"]);
  });
});
