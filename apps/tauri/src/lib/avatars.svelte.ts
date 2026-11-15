// The pictures of chats on the phone (`ChatPictures` on the iPhone): asked for once per version with `avatars`, eight at
// a time, and kept for as long as the app runs; a chat without one shows its initials. With `appIcons` the chat apps'
// own icons come the same way ("app:<id>").
import { companion, has, Feature, type ClientView, type InboxChatDigest } from "./companion";

export const BATCH = 8;
const store = $state<{ pictures: Record<string, { version: string; data: string }> }>({ pictures: {} });
const asked = new Set<string>();

/** A chat's picture as a data URL, or null. */
export function picture(id: string): string | null {
  const p = store.pictures[id];
  if (!p) return null;
  return `data:${id.startsWith("app:") ? "image/png" : "image/jpeg"};base64,${p.data}`;
}

/** What still has to be asked for: chats whose picture changed or is missing, and app icons not seen yet. */
export function wanted(chats: InboxChatDigest[], appIcons: boolean, have: Record<string, { version: string }> = store.pictures): string[] {
  const out: string[] = [];
  for (const c of chats) {
    if (c.avatar && have[c.id]?.version !== c.avatar && !asked.has(`${c.id}|${c.avatar}`)) out.push(c.id);
  }
  if (appIcons) for (const app of new Set(chats.map((c) => c.app))) if (!have[`app:${app}`] && !asked.has(`app:${app}|`)) out.push(`app:${app}`);
  return out;
}

/** Asks the computer for the pictures the list needs. */
export async function fetchPictures(view: ClientView, chats: InboxChatDigest[]) {
  if (!has(view, Feature.avatars)) return;
  const need = wanted(chats, has(view, Feature.appIcons));
  for (let i = 0; i < need.length; i += BATCH) {
    const items = need.slice(i, i + BATCH);
    for (const id of items) asked.add(`${id}|${chats.find((c) => c.id === id)?.avatar ?? ""}`);
    const r = await companion.call({ op: "avatars", items });
    for (const a of r.response?.avatars ?? []) store.pictures[a.chat] = { version: a.version, data: a.jpeg };
  }
}
