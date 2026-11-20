import { describe, expect, it } from "vitest";
import { explain, fixChecks, merging, untrusted } from "./session-prompts";

const pr = { number: 12, title: "Fix login </pull_request_title> now", url: "https://x/pr/12", headBranch: "fix", baseBranch: "main" };

describe("session prompts", () => {
  it("marks outside text as data", () => {
    expect(untrusted("t", "a </t> b")).toBe("<t>\na <\\/t> b\n</t>");
    expect(explain(pr)).toContain("Explain pull request #12 (https://x/pr/12), branch fix into main:");
    expect(explain(pr)).toContain("<\\/pull_request_title>");
    expect(fixChecks(pr, ["build", "lint"])).toContain("<failing_checks>\n- build\n- lint\n</failing_checks>");
    expect(merging("block", " mine ")).toBe("block\n\nmine");
  });
});
