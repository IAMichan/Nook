import { describe, expect, it } from "vitest";
import { BANNER_LOGO_LIMIT, MENU_INLINE_LIMIT, shownConnectors, waitingConnector } from "./connector-sign-in";
import type { ConnectorSignIn } from "./api";

const sample: ConnectorSignIn[] = [
  { name: "claude.ai Figma", title: "Figma", iconDomain: "figma.com", waiting: false },
  { name: "claude.ai Linear", title: "Linear", iconDomain: "linear.app", waiting: true },
  { name: "plugin:work:supabase", title: "supabase", iconDomain: "supabase.com", waiting: false },
];

describe("connector-sign-in helpers", () => {
  it("hides dismissed connectors unless they are actively waiting", () => {
    const shown = shownConnectors(sample, ["claude.ai Figma", "claude.ai Linear"]);
    expect(shown.map((c) => c.name)).toEqual(["claude.ai Linear", "plugin:work:supabase"]);
  });

  it("supports Set inputs and returns all when nothing is dismissed", () => {
    const shown = shownConnectors(sample, new Set<string>());
    expect(shown).toHaveLength(3);
  });

  it("finds the first waiting connector", () => {
    expect(waitingConnector(sample)?.title).toBe("Linear");
    expect(waitingConnector([sample[0]])).toBeUndefined();
  });

  it("matches macOS banner and menu limits", () => {
    expect(BANNER_LOGO_LIMIT).toBe(3);
    expect(MENU_INLINE_LIMIT).toBe(3);
  });
});
