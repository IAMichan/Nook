import { describe, expect, it } from "vitest";
import { fencedMail, quotedMail, splitMailBlocks, type MailTemplate } from "./mail-block";

const mail = (fields: Partial<MailTemplate>): MailTemplate => ({ from: "", to: "", cc: "", bcc: "", subject: "", body: "", ...fields });

describe("fenced mail blocks", () => {
  it("read headers, a blank line, then the body", () => {
    const parts = splitMailBlocks(
      "Here it is:\n\n```mail\nTo: lisa@example.nl\nCc: jan@example.nl\nBcc: boss@example.nl\n**Subject:** Lunch\n\nHi Lisa,\n\nTuesday?\n```\n\nShall I send it?",
    );
    expect(parts).toEqual([
      { kind: "markdown", text: "Here it is:\n" },
      { kind: "mail", mail: mail({ to: "lisa@example.nl", cc: "jan@example.nl", bcc: "boss@example.nl", subject: "Lunch", body: "Hi Lisa,\n\nTuesday?" }) },
      { kind: "markdown", text: "\nShall I send it?" },
    ]);
  });

  it("accept every fence name and the header names of the five languages", () => {
    for (const lang of ["mail", "email", "e-mail", "EML"]) {
      expect(splitMailBlocks(`\`\`\`${lang}\nText\n\`\`\``)).toEqual([{ kind: "mail", mail: mail({ body: "Text" }) }]);
    }
    expect(fencedMail("Van: ik@example.nl\nAan: lisa@example.nl\nKopie: a@b.nl\nBKopie: c@d.nl\nOnderwerp: Hoi\n\nTekst")).toEqual(
      mail({ from: "ik@example.nl", to: "lisa@example.nl", cc: "a@b.nl", bcc: "c@d.nl", subject: "Hoi", body: "Tekst" }),
    );
    expect(fencedMail("An: a@b.de\nBetreff: Hallo\n\nText").subject).toBe("Hallo");
    expect(fencedMail("À: a@b.fr\nCCI: c@d.fr\nObjet: Salut\n\nTexte")).toEqual(mail({ to: "a@b.fr", bcc: "c@d.fr", subject: "Salut", body: "Texte" }));
    expect(fencedMail("Para: a@b.es\nCCO: c@d.es\nAsunto: Hola\n\nTexto")).toEqual(mail({ to: "a@b.es", bcc: "c@d.es", subject: "Hola", body: "Texto" }));
  });

  it("take the whole block as the body without header lines", () => {
    expect(fencedMail("Hi Lisa,\n\nNote: tomorrow.\n")).toEqual(mail({ body: "Hi Lisa,\n\nNote: tomorrow." }));
  });

  it("leave other code blocks alone, also when they hold a quote", () => {
    const source = "```text\n> Hi Jan,\n> Fine.\n> Regards,\n```";
    expect(splitMailBlocks(source)).toEqual([{ kind: "markdown", text: source }]);
  });

  it("run to the end while an answer still streams", () => {
    expect(splitMailBlocks("```mail\nSubject: Hi\n\nHello")).toEqual([{ kind: "mail", mail: mail({ subject: "Hi", body: "Hello" }) }]);
  });
});

describe("quoted mails", () => {
  it("become a card with a greeting and a sign-off", () => {
    const parts = splitMailBlocks("Try this:\n\n> Hi Jan,\n>\n> Can we move our call to Thursday?\n>\n> Kind regards,\n> Lisa\n\nOr shorter.");
    expect(parts[1]).toEqual({ kind: "mail", mail: mail({ body: "Hi Jan,\n\nCan we move our call to Thursday?\n\nKind regards,\nLisa" }) });
    expect(parts).toHaveLength(3);
  });

  it("know greetings and sign-offs in the other languages", () => {
    expect(quotedMail("Beste Jan,\nZullen we donderdag bellen?\nMet vriendelijke groet,\nLisa")).not.toBeNull();
    expect(quotedMail("Hoi,\nKan het morgen?\nGroetjes!")).not.toBeNull();
    expect(quotedMail("Sehr geehrte Frau Müller,\nAnbei die Unterlagen.\nMit freundlichen Grüßen")).not.toBeNull();
    expect(quotedMail("Bonjour Marie,\nÀ demain.\nCordialement,\nLisa")).not.toBeNull();
    expect(quotedMail("Hola Ana,\n¿Nos vemos?\nSaludos.")).not.toBeNull();
  });

  it("become a card when they open with headers", () => {
    expect(quotedMail("**To:** jan@example.nl\nSubject: Call\n\nThursday works.")).toEqual(
      mail({ to: "jan@example.nl", subject: "Call", body: "Thursday works." }),
    );
    // Headers without a recipient or subject, or without a body, stay a quote.
    expect(quotedMail("Cc: jan@example.nl\n\nThursday works.")).toBeNull();
    expect(quotedMail("Subject: Call")).toBeNull();
  });

  it("stay quotes when they do not read as a mail", () => {
    expect(splitMailBlocks("> Hi Jan,\n> Regards")).toEqual([{ kind: "markdown", text: "> Hi Jan,\n> Regards" }]);
    expect(quotedMail("Hi Jan, this is a long first line that does not end with a comma\nText\nRegards,")).toBeNull();
    expect(quotedMail("Hi Jan,\nOne\nTwo\nThree\nFour\nRegards,\nFive\nSix\nSeven")).toBeNull();
    expect(quotedMail("Hiya,\nText\nRegards,")).toBeNull();
    expect(quotedMail("Note, this is it\nText\nRegards,")).toBeNull();
  });
});

describe("plain answers", () => {
  it("stay one Markdown part", () => {
    expect(splitMailBlocks("Just **text**.\n\n- a\n- b")).toEqual([{ kind: "markdown", text: "Just **text**.\n\n- a\n- b" }]);
  });
});
