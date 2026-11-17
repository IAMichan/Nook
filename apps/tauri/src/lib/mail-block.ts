// Mails an answer writes for the user to send, shown as a mail card instead of a block of text (parity with
// `MailTemplate.swift` on the Mac). An answer writes one as a ```mail block (also ```email, ```e-mail, ```eml): header
// lines (`To:`, `Cc:`, `Bcc:`, `Subject:`, `From:`, also in the five app languages), a blank line, then the text. A
// quote that reads as a mail (headers at the top, or a greeting and a sign-off) becomes a card too.

export interface MailTemplate {
  from: string;
  to: string;
  cc: string;
  bcc: string;
  subject: string;
  body: string;
}

export type MarkdownSegment = { kind: "markdown"; text: string } | { kind: "mail"; mail: MailTemplate };

/** The fence languages that hold a mail. */
export const mailLanguages = new Set(["mail", "email", "e-mail", "eml"]);

type Header = "from" | "to" | "cc" | "bcc" | "subject";

/** Header names, lowercased, in English, Dutch, German, French and Spanish. */
const headers: Record<string, Header> = {
  from: "from", van: "from", von: "from", de: "from", sender: "from", afzender: "from",
  to: "to", aan: "to", an: "to", "à": "to", a: "to", para: "to", recipient: "to", recipients: "to",
  ontvanger: "to", ontvangers: "to", destinataire: "to", destinataires: "to", "empfänger": "to",
  cc: "cc", kopie: "cc", copie: "cc", copia: "cc",
  bcc: "bcc", cci: "bcc", cco: "bcc", bkopie: "bcc",
  subject: "subject", onderwerp: "subject", betreff: "subject", objet: "subject", asunto: "subject",
};

/** Words a mail opens with, lowercased, in the five app languages. */
const greetings = [
  "hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening",
  "hoi", "hallo", "beste", "lieve", "geachte", "goedemorgen", "goedemiddag", "goedenavond", "dag",
  "liebe", "lieber", "sehr geehrte", "sehr geehrter", "guten tag", "moin",
  "bonjour", "bonsoir", "cher", "chère", "salut", "madame", "monsieur",
  "hola", "estimado", "estimada", "buenos días", "buenas tardes", "querido", "querida",
];

/** Lines a mail closes with, lowercased, without their trailing punctuation. */
const signOffs = new Set([
  "regards", "kind regards", "best regards", "best", "cheers", "thanks", "thank you", "sincerely", "yours sincerely",
  "all the best", "warm regards",
  "groet", "groeten", "met vriendelijke groet", "met vriendelijke groeten", "vriendelijke groet", "hartelijke groet",
  "hartelijke groeten", "groetjes", "liefs", "dank", "bedankt", "alvast bedankt", "mvg", "gr",
  "grüße", "gruß", "viele grüße", "beste grüße", "mit freundlichen grüßen", "lg", "vg",
  "cordialement", "bien à vous", "bien cordialement", "salutations", "merci", "à bientôt", "bises",
  "saludos", "un saludo", "atentamente", "un abrazo", "gracias", "cordiales saludos",
]);

const emptyMail = (): MailTemplate => ({ from: "", to: "", cc: "", bcc: "", subject: "", body: "" });

/** The header a line opens (`**Subject:** Hello` too) and its value; null when the line is text. */
function header(line: string): [Header, string] | null {
  const plain = line.replaceAll("**", "").replaceAll("__", "").trim();
  const colon = plain.indexOf(":");
  if (colon < 0) return null;
  const name = plain.slice(0, colon).trim().toLowerCase();
  const kind = name.length <= 14 ? headers[name] : undefined;
  return kind ? [kind, plain.slice(colon + 1).trim()] : null;
}

/** Reads header lines from the top of `text`; the rest is the body. Null when headers are needed and none came. */
function read(text: string, needsHeaders: boolean): MailTemplate | null {
  const lines = text.split("\n");
  const mail = emptyMail();
  let found = 0;
  while (lines.length) {
    const trimmed = lines[0].trim();
    if (!trimmed) {
      lines.shift();
      // The blank line after the headers starts the text; one before any header is skipped.
      if (found > 0) break;
      continue;
    }
    const parsed = header(trimmed);
    if (!parsed) break;
    mail[parsed[0]] = parsed[1];
    found += 1;
    lines.shift();
  }
  if (needsHeaders && found === 0) return null;
  mail.body = lines.join("\n").trim();
  return mail;
}

/** The mail in a ```mail block. Without any header line, all of it is the text. */
export function fencedMail(body: string): MailTemplate {
  return read(body, false) ?? { ...emptyMail(), body: body.trim() };
}

function opensWithGreeting(line: string): boolean {
  const lower = line.trim().toLowerCase();
  if (!lower.endsWith(",") || [...lower].length > 60) return false;
  return greetings.some((g) => lower === `${g},` || lower.startsWith(`${g} `));
}

function isSignOff(line: string): boolean {
  return signOffs.has(line.trim().toLowerCase().replace(/[,.!]+$/, ""));
}

/** A quote that is a mail: it opens with mail headers, or with a greeting and closes with a sign-off near its end. */
export function quotedMail(text: string): MailTemplate | null {
  const withHeaders = read(text, true);
  if (withHeaders && (withHeaders.to || withHeaders.subject) && withHeaders.body) return withHeaders;
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  if (lines.length < 3 || !opensWithGreeting(lines[0]) || !lines.slice(-3).some(isSignOff)) return null;
  return { ...emptyMail(), body: text.trim() };
}

const fenceLanguage = (line: string) => line.slice(3).trim().split(/\s+/)[0]?.toLowerCase() ?? "";

/**
 * Splits Markdown into plain Markdown and mails. Other code blocks stay Markdown, also when they hold a quote or a
 * ```mail line. An unclosed ```mail block (an answer still streaming) runs to the end, like any code block.
 */
export function splitMailBlocks(source: string): MarkdownSegment[] {
  // Fast path: most answers hold no mail at all.
  if (!/```|^\s*>/m.test(source)) return [{ kind: "markdown", text: source }];
  const lines = source.split("\n");
  const segments: MarkdownSegment[] = [];
  let pending: string[] = [];
  const flush = () => {
    if (pending.some((l) => l.trim())) segments.push({ kind: "markdown", text: pending.join("\n") });
    pending = [];
  };
  let i = 0;
  while (i < lines.length) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith("```")) {
      const start = i;
      i += 1;
      while (i < lines.length && !lines[i].trim().startsWith("```")) i += 1;
      const end = Math.min(i, lines.length);
      i += 1;
      if (mailLanguages.has(fenceLanguage(trimmed))) {
        flush();
        segments.push({ kind: "mail", mail: fencedMail(lines.slice(start + 1, end).join("\n")) });
      } else {
        pending.push(...lines.slice(start, Math.min(i, lines.length)));
      }
      continue;
    }
    if (trimmed.startsWith(">")) {
      const start = i;
      const quote: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith(">")) quote.push(lines[i++].trim().slice(1).trim());
      const mail = quotedMail(quote.join("\n"));
      if (mail) {
        flush();
        segments.push({ kind: "mail", mail });
      } else {
        pending.push(...lines.slice(start, i));
      }
      continue;
    }
    pending.push(lines[i]);
    i += 1;
  }
  flush();
  return segments.length ? segments : [{ kind: "markdown", text: source }];
}
