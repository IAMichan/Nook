// Birthdays for Today (the Mac's `birthdayAttention`): the people you gave a birthday in a chat's info, and all-day
// "birthday" events in your linked calendars (Google's birthdays calendar, a contact's anniversary), today only.
// Pure, so the calendar side is tested.

const WORDS = /\b(birthday|verjaardag|jarig|geburtstag|anniversaire|cumpleaños|cumpleanos)\b/i;

export interface DayEvent { title: string; start: string; allDay: boolean }

/// The all-day events today that are someone's birthday, with the person's name when the title gives it
/// ("Anna's birthday", "Verjaardag van Anna", "Anna – Geburtstag").
export function calendarBirthdays(events: DayEvent[], today = new Date()): { name: string; title: string }[] {
  const day = today.toDateString();
  return events
    .filter((e) => e.allDay && WORDS.test(e.title) && new Date(e.start).toDateString() === day)
    .map((e) => ({ title: e.title, name: nameIn(e.title) }));
}

function nameIn(title: string): string {
  const cleaned = title
    .replace(/['’]s\b/i, "")
    .replace(WORDS, "")
    .replace(/\b(van|von|de|of|du)\b/gi, "")
    .replace(/[🎂🎉🎈\-–—:()]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned || title;
}
