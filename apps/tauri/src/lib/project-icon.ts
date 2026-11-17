// A project's icon (`ProjectIcon` in apps/macos/Services/Workspace/ProjectSettings.swift): an emoji, one or two letters
// on a tint (a monogram), or an image file, stored as one string ("emoji:🚀", "monogram:NK:mint", "image:/path.png").
// Until you set one, a project shows its initials on a tint picked from its name, the same on every computer.

export const PROJECT_TINTS = ["mint", "amber", "coral", "violet", "blue", "music"] as const;
export type ProjectTint = (typeof PROJECT_TINTS)[number];

export type ProjectIcon =
  | { kind: "emoji"; emoji: string }
  | { kind: "monogram"; letters: string; tint: ProjectTint }
  | { kind: "image"; path: string };

const isTint = (v: string): v is ProjectTint => (PROJECT_TINTS as readonly string[]).includes(v);
const isAbsolute = (p: string) => p.startsWith("/") || /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\");

/** The first character of the text, when it is an emoji. */
export function cleanEmoji(text: string): string | null {
  // One emoji with what joins it: a flag's two letters, or a pictograph with its skin tone, variation and ZWJ parts.
  const t = text.trim();
  const flag = t.match(/^[\u{1F1E6}-\u{1F1FF}]{2}/u);
  if (flag) return flag[0];
  const one = t.match(/^\p{Extended_Pictographic}(?:\uFE0F|\p{Emoji_Modifier}|\u200D\p{Extended_Pictographic}\uFE0F?\p{Emoji_Modifier}?)*/u)?.[0];
  if (!one) return null;
  const c = [...one][0];
  return /\p{Emoji_Presentation}/u.test(c) || c.codePointAt(0)! > 0xff ? one : null;
}

/** One or two letters or digits, upper-cased; null when the text has none. */
export function cleanMonogram(text: string): string | null {
  const letters = [...text].filter((c) => /[\p{L}\p{N}]/u.test(c)).slice(0, 2).join("").toUpperCase();
  return letters || null;
}

/** Reads a stored icon; anything unknown is null. */
export function parseProjectIcon(stored: string | null | undefined): ProjectIcon | null {
  if (!stored) return null;
  const i = stored.indexOf(":");
  if (i < 0) return null;
  const kind = stored.slice(0, i);
  const rest = stored.slice(i + 1);
  if (kind === "emoji") {
    const emoji = cleanEmoji(rest);
    return emoji ? { kind, emoji } : null;
  }
  if (kind === "monogram") {
    const j = rest.indexOf(":");
    const letters = cleanMonogram(j < 0 ? rest : rest.slice(0, j));
    const tint = j < 0 ? "mint" : rest.slice(j + 1);
    return letters ? { kind, letters, tint: isTint(tint) ? tint : "mint" } : null;
  }
  if (kind === "image") return isAbsolute(rest) ? { kind, path: rest } : null;
  return null;
}

export function storedProjectIcon(icon: ProjectIcon): string {
  switch (icon.kind) {
    case "emoji": return `emoji:${icon.emoji}`;
    case "monogram": return `monogram:${icon.letters}:${icon.tint}`;
    case "image": return `image:${icon.path}`;
  }
}

/** The first letters of the first two words of a folder name, or its first two letters when it is one word. */
export function projectInitials(folderName: string): string {
  const words = folderName.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const letters = words.length > 1 ? words.slice(0, 2).map((w) => [...w][0]).join("") : [...(words[0] ?? "")].slice(0, 2).join("");
  return letters ? letters.toUpperCase() : "?";
}

/** The tint a project gets until you choose one: FNV-1a over the lower-cased name's UTF-8, as the Mac picks it. */
export function defaultProjectTint(name: string): ProjectTint {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(name.toLowerCase())) {
    hash ^= byte;
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return PROJECT_TINTS[hash % PROJECT_TINTS.length];
}

export function defaultProjectIcon(name: string): ProjectIcon {
  return { kind: "monogram", letters: projectInitials(name), tint: defaultProjectTint(name) };
}

/** The theme color of a tint. */
export const tintColor = (tint: ProjectTint) => `var(--${tint})`;
