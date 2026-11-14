import { describe, expect, it } from "vitest";
import { deletable, folderName, shownArchived } from "./archive";

type Item = { id: string; title: string; archived: boolean; updated: string; busy?: boolean };
const items: Item[] = [
  { id: "a", title: "Trip to Lisbon", archived: true, updated: "2026-01-01T10:00:00Z" },
  { id: "b", title: "Budget review", archived: true, updated: "2026-03-01T10:00:00Z", busy: true },
  { id: "c", title: "Lisbon hotels", archived: false, updated: "2026-04-01T10:00:00Z" },
  { id: "d", title: "Réunion équipe", archived: true, updated: "2026-02-01T10:00:00Z" },
];
const show = (q: string) => shownArchived(items, q, (i) => i.archived, (i) => [i.title], (i) => i.updated).map((i) => i.id);

describe("archive", () => {
  it("shows only archived items, newest first, narrowed by every word of the search", () => {
    expect(show("")).toEqual(["b", "d", "a"]);
    expect(show("lisbon")).toEqual(["a"]);
    expect(show("reunion")).toEqual(["d"]);
    expect(show("nothing here")).toEqual([]);
  });

  it("never deletes something that still works", () => {
    expect(deletable(items, (i) => !!i.busy).map((i) => i.id)).toEqual(["a", "c", "d"]);
  });

  it("names a folder by its last part on every platform", () => {
    expect(folderName("C:\\code\\web")).toBe("web");
    expect(folderName("/home/sam/api/")).toBe("api");
  });
});
