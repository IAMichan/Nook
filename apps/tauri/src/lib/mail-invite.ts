import type { CalendarInviteEvent, MailDraft } from "./brain";

/** Formats `"Lunch · Tue 17 Nov 12:30–13:30"` in the given BCP 47 locale. */
export function inviteSummary(invite: CalendarInviteEvent, locale: string): string {
  const start = new Date(invite.start);
  const end = new Date(invite.end);
  if (Number.isNaN(start.getTime())) return invite.title;
  const day = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short" }).format(start);
  const clock = new Intl.DateTimeFormat(locale, { hour: "2-digit", minute: "2-digit", hour12: false });
  const startClock = clock.format(start);
  if (Number.isNaN(end.getTime())) return `${invite.title} · ${day} ${startClock}`;
  return `${invite.title} · ${day} ${startClock}–${clock.format(end)}`;
}

export function hasInviteFile(draft: Pick<MailDraft, "attachments">): boolean {
  return (draft.attachments ?? []).some((path) => path.endsWith("invite.ics"));
}
