import { describe, expect, it } from "vitest";
import {
  citationLabel,
  citationReferences,
  citationsUsed,
  claimFromTextBefore,
  clipPassageLine,
  pickPassage,
  referenceOrigin,
  referenceSender,
  referenceShortTitle,
  withoutSourceList,
} from "./citations";
import { renderAnswerMarkdown, renderMarkdown } from "./markdown";
import type { SourceReference } from "./types";

describe("citationsUsed & withoutSourceList", () => {
  it("extracts cited numbers without matching markdown links", () => {
    expect([...citationsUsed("Fact [1], pair [2, 12] and [link](https://example.com) [3].")]).toEqual([1, 2, 12, 3]);
  });

  it("drops a model-written Sources line", () => {
    const text =
      "Sources: [4] infaris.com: Achterstallige Rekening, Vimexx · [8] WhatsApp +31 6 19304231\n\nHet concept-antwoord aan Laura staat klaar [30].";
    expect(withoutSourceList(text)).toBe("Het concept-antwoord aan Laura staat klaar [30].");
  });

  it("drops a Sources or Bronnen heading with its cited list", () => {
    expect(withoutSourceList("Klaar [1].\n\n**Bronnen:**\n- [1] Vimexx\n- [2] Agenda")).toBe("Klaar [1].");
    expect(withoutSourceList("Klaar [1].\n\n## Sources\n\n[1] Vimexx")).toBe("Klaar [1].");
  });

  it("keeps ordinary prose mentioning sources", () => {
    for (const text of [
      "Bronwater is gezond [2].",
      "Sources say the deadline moved [1].",
      "Bron: niets gevonden.",
      "## Sources\nNone of them answered.",
    ]) {
      expect(withoutSourceList(text)).toBe(text);
    }
  });
});

describe("reference labels & sender", () => {
  it("labels mail sources by sender and ignores non-mail or numeric details", () => {
    const mail: SourceReference = {
      number: 1,
      sourceId: "mail",
      title: "Achterstallige rekening infaris.com",
      detail: "Vimexx · 2026-11-14",
    };
    expect(referenceSender(mail)).toBe("Vimexx");
    const event: SourceReference = { number: 2, sourceId: "calendar", title: "Retro", detail: "16 nov · Werk" };
    expect(referenceSender(event)).toBeNull();
  });

  it("strips short app prefixes and builds grouped labels", () => {
    const chat: SourceReference = { number: 1, sourceId: "whatsapp", title: "WhatsApp: Mama Jis", detail: "16 nov" };
    const mail: SourceReference = {
      number: 2,
      sourceId: "mail",
      title: "Very long email subject that should not fit",
      detail: "Laura van Ekris · 15 nov",
    };
    expect(referenceShortTitle(chat)).toBe("Mama Jis");
    expect(referenceOrigin(chat)).toBe("WhatsApp · 16 nov");
    expect(citationLabel([chat, mail])).toBe("Mama Jis +1");
    expect(citationLabel(citationReferences([2], [chat, mail]))).toBe("Laura van Ekris");
  });
});

describe("pickPassage & clipPassageLine", () => {
  const mailExcerpt = [
    "Achterstallige rekening | from Vimexx <billing@vimexx.nl> | 2026-11-14",
    "De registratie van infaris.com verloopt op 20 november.",
    "Betaal de openstaande factuur om de domeinnaam te behouden.",
  ].join("\n");

  it("marks the lines that match the claim", () => {
    const lines = pickPassage(mailExcerpt, "Herinnering om de verlenging van infaris.com bij Vimexx te betalen");
    expect(lines).toHaveLength(3);
    expect(lines[1].relevant).toBe(true);
    expect(lines[1].text).toContain("infaris.com");
  });

  it("strips whole-word title prefix and reformats ISO times and pipes", () => {
    const lines = pickPassage(
      "Retro | 2026-11-16T13:00:00+01:00 – 2026-11-16T14:00 | Heemskerk\nAgenda: sprint",
      "retro om 13:00",
      "Retro",
    );
    expect(lines.map((l) => l.text)).toEqual(["2026-11-16 13:00 – 2026-11-16 14:00 · Heemskerk", "Agenda: sprint"]);
    expect(pickPassage("Retrospective team", "", "Retro").map((l) => l.text)).toEqual(["Retrospective team"]);
  });

  it("returns the first lines unmarked when nothing matches", () => {
    const lines = pickPassage("One\nTwo\nThree", "zzzz");
    expect(lines.map((l) => l.text)).toEqual(["One", "Two", "Three"]);
    expect(lines.some((l) => l.relevant)).toBe(false);
  });

  it("clips long lines around the match", () => {
    const line = `${"a ".repeat(200)}infaris.com verloopt${" b".repeat(200)}`;
    const clipped = clipPassageLine(line, "infaris", 60);
    expect(clipped).toContain("infaris");
    expect(clipped.startsWith("…") && clipped.endsWith("…")).toBe(true);
  });

  it("extracts the sentence backing a citation", () => {
    expect(claimFromTextBefore("First sentence. The domain expires on Nov 20")).toBe("The domain expires on Nov 20");
    expect(claimFromTextBefore("Just one clause")).toBe("Just one clause");
  });
});

describe("renderAnswerMarkdown", () => {
  const refs: SourceReference[] = [
    {
      number: 1,
      sourceId: "mail",
      title: "Achterstallige rekening",
      detail: "Vimexx · 2026-11-14",
      url: "message:%3Cabc@vimexx%3E",
      excerpt: "De registratie van infaris.com verloopt op 20 november.",
    },
    {
      number: 2,
      sourceId: "whatsapp",
      title: "WhatsApp: Mama Jis",
      detail: "16 nov",
    },
  ];

  it("renders inline citation pills for backed citations and strips Sources lists", () => {
    const html = renderAnswerMarkdown(
      "Je domein verloopt [1, 2]. Volgens mij onbekend [9].\n\nSources: [1] Vimexx · [2] Mama Jis",
      refs,
    );
    expect(html).toContain('class="cite-pill"');
    expect(html).toContain('data-cites="1,2"');
    expect(html).toContain("Vimexx +1");
    expect(html).toContain('<sup class="cite" data-cite="9">9</sup>');
    expect(html).not.toContain("Sources:");
  });

  it("leaves citations in code and links untouched and leaves plain renderMarkdown intact", () => {
    const html = renderAnswerMarkdown("Use `[1]` and [link](https://nook.app) [1].", refs);
    expect(html).toContain("<code>[1]</code>");
    expect(html).toContain('<a href="https://nook.app/" data-external title="https://nook.app/">link</a>');
    expect(renderMarkdown("Fact [1].")).toContain('<sup class="cite" data-cite="1">1</sup>');
  });
});
