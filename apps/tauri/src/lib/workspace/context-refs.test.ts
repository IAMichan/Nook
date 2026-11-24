import { describe, expect, it } from "vitest";
import { compose, fileRef, find, link, project, timeline } from "./context-refs";

describe("context references", () => {
  it("links read back as the same reference", () => {
    const ref = { kind: "file" as const, id: "Sources/Login [old].swift", label: "Login [old].swift" };
    const found = find(`see ${link(ref)} now`);
    expect(found.map((f) => [f.kind, f.id, f.label])).toEqual([["file", "Sources/Login [old].swift", "Login (old).swift"]]);
  });

  it("gives the agent markers and one envelope, then the pictures", () => {
    const text = compose("Fix @Login.swift please", [fileRef("/w/docs")], [fileRef("Sources/Login.swift")]);
    const out = project(text, ["/p/shot.png"]);
    expect(out).toBe(
      'Fix @Login.swift please\n\n@docs\n\n<nook_context>\n<ref kind="file" id="Sources/Login.swift"/>\n<ref kind="file" id="/w/docs"/>\n</nook_context>\n/p/shot.png',
    );
    expect(timeline(out, "/w")).toEqual({ words: "Fix @Login.swift please", paths: ["/w/docs", "/p/shot.png"] });
  });

  it("links pull requests and skills typed as #12 and $name", () => {
    const pr = { kind: "pullRequest" as const, id: "me/app#12", label: "12" };
    const skill = { kind: "skill" as const, id: "deploy", label: "deploy" };
    const out = project(compose("Use $deploy for #12", [], [pr, skill]));
    expect(out).toBe('Use $deploy for #12\n\n<nook_context>\n<ref kind="skill" id="deploy"/>\n<ref kind="pullRequest" id="me/app#12"/>\n</nook_context>');
  });

  it("leaves a message without references alone", () => {
    expect(project("just words")).toBe("just words");
    expect(timeline("just words")).toEqual({ words: "just words", paths: [] });
    expect(timeline("look\n/p/shot.png")).toEqual({ words: "look", paths: ["/p/shot.png"] });
  });
});
