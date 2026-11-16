import { describe, expect, it } from "vitest";
import { LINKS, readableSize } from "./maintenance";

describe("maintenance", () => {
  it("writes sizes for people", () => {
    expect(readableSize(0)).toBe("0 KB");
    expect(readableSize(340 * 1024)).toBe("340 KB");
    expect(readableSize(12.4 * 1024 * 1024)).toBe("12.4 MB");
    expect(readableSize(3 * 1024 ** 3)).toBe("3.0 GB");
  });

  it("links to the repository over https", () => {
    for (const url of Object.values(LINKS)) expect(url.startsWith("https://github.com/IAMichan/nook")).toBe(true);
  });
});
