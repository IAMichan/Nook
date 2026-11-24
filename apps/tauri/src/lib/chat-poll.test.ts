import { describe, expect, it } from "vitest";
import { choiceAfter, voting, type ChatPoll } from "./chat-poll";

const poll = (multiple: boolean): ChatPoll => ({ question: "Lunch?", multiple, options: [{ text: "Sushi", votes: 1, chosen: false }, { text: "Pizza", votes: 0, chosen: false }] });

describe("a poll", () => {
  it("picks, replaces and takes back your choice", () => {
    const one = voting(poll(false), ["Sushi"]);
    expect(one.options[0]).toMatchObject({ chosen: true, votes: 2 });
    expect(choiceAfter(one, "Pizza")).toEqual(["Pizza"]);
    expect(choiceAfter(one, "Sushi")).toEqual([]);
    expect(voting(one, ["Pizza"]).options.map((o) => o.votes)).toEqual([1, 1]);
  });
  it("adds to your choice when more answers may be chosen", () => {
    expect(choiceAfter(voting(poll(true), ["Sushi"]), "Pizza")).toEqual(["Sushi", "Pizza"]);
  });
});
