import { describe, expect, it } from "vitest";
import { compose, find } from "./context-refs";
import { buildSessionLink, findSessionLinks, parseSessionLink, replacingPasted } from "./session-link";

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";

describe("session-link (SessionLink)", () => {
  it("builds a link only for a UUID", () => {
    expect(buildSessionLink(ID, "Fix the login")).toBe("nook://session/3f2504e0-4f89-11d3-9a0c-0305e82c3301?title=Fix%20the%20login");
    expect(buildSessionLink("../etc", "x")).toBeNull();
    expect(buildSessionLink(ID, "  ")).toBe("nook://session/3f2504e0-4f89-11d3-9a0c-0305e82c3301");
  });

  it("parses what it builds, and names an untitled one by its id", () => {
    expect(parseSessionLink(buildSessionLink(ID, "Fix the login")!)).toEqual({ id: ID.toLowerCase(), title: "Fix the login" });
    expect(parseSessionLink(`nook://session/${ID}`)).toEqual({ id: ID.toLowerCase(), title: "3f2504e0" });
    expect(parseSessionLink("nook://session/not-a-uuid")).toBeNull();
    expect(parseSessionLink(`nook://session/${ID}/more`)).toBeNull();
    expect(parseSessionLink("https://example.com")).toBeNull();
  });

  it("cuts long titles and drops control characters", () => {
    const parsed = parseSessionLink(`nook://session/${ID}?title=${encodeURIComponent("a\u0007b" + "x".repeat(300))}`)!;
    expect(parsed.title.startsWith("ab")).toBe(true);
    expect([...parsed.title].length).toBe(200);
  });

  it("turns a pasted bare link into a session mention", () => {
    const pasted = `look at ${buildSessionLink(ID, "Login")} please`;
    const result = replacingPasted("look at ", pasted)!;
    expect(result.text).toBe("look at @Login please");
    const refs = find(compose(result.text, [], result.refs));
    expect(refs).toHaveLength(1);
    expect(refs[0]).toMatchObject({ kind: "session", id: ID.toLowerCase(), label: "Login" });
    // Nothing new: nothing changes.
    expect(replacingPasted(pasted, pasted)).toBeNull();
    expect(replacingPasted("a", "ab")).toBeNull();
  });

  it("finds several links in order", () => {
    const text = `${buildSessionLink(ID, "One")} and (${buildSessionLink(ID.replace("3F", "4F"), "Two")})`;
    expect(findSessionLinks(text).map((f) => f.link.title)).toEqual(["One", "Two"]);
  });
});
