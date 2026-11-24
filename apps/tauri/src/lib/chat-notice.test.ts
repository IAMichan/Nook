import { describe, expect, it } from "vitest";
import { groupChangeLine, membershipLine, nameList, noticeText, ME, SOMEONE } from "./chat-notice";

describe("chat notice lines", () => {
  it("says who added whom, with you in the right place", () => {
    expect(membershipLine({ change: "added", by: "Ruben", people: ["David", "Anna"] })).toMatch(/Ruben added David and Anna|Ruben heeft David en Anna toegevoegd/);
    expect(membershipLine({ change: "added", by: ME, people: ["Jan"] })).toMatch(/You added Jan|Je hebt Jan toegevoegd/);
    expect(membershipLine({ change: "removed", by: "Ruben", people: [ME] })).toMatch(/Ruben removed you|Ruben heeft je verwijderd/);
  });

  it("puts you last in a list", () => {
    expect(nameList([ME, "David", "Anna"]).endsWith(nameList([ME]))).toBe(true);
  });

  it("says joined, left and gone per person", () => {
    expect(membershipLine({ change: "left", people: ["Anna"] })).toMatch(/Anna/);
    expect(membershipLine({ change: "joined", people: [ME] })).toMatch(/You joined|Je bent lid geworden/);
    expect(membershipLine({ change: "gone", people: [] })).toMatch(/Someone|Iemand/);
  });

  it("says what changed in the group", () => {
    expect(groupChangeLine({ kind: "renamed", by: "Anna", text: "Club" })).toMatch(/Club/);
    expect(groupChangeLine({ kind: "disappearing", by: SOMEONE, text: "604800" })).toMatch(/week|Woche|semaine|semana/i);
    expect(groupChangeLine({ kind: "disappearing", by: ME, text: "0" })).toMatch(/off|uitgezet/);
  });

  it("is no line for a message", () => {
    expect(noticeText({})).toBeNull();
    expect(noticeText({ groupChange: { kind: "photo", by: "Bo" } })).toMatch(/Bo/);
  });
});
