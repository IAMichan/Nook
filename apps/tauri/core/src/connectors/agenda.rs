//! Eén blik op alle agenda's: agenda's via een ICS-adres en Cal.com (op de Mac ook Apple Agenda), zodat Nook "ben ik
//! 13 oktober beschikbaar?" kan beantwoorden zonder te vragen welke agenda.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{dates, short, ConnectorError};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaEntry {
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub all_day: bool,
    /// Onwaar als de afspraak op "vrij"/"beschikbaar" staat.
    pub busy: bool,
    pub location: String,
    /// De agenda waar hij vandaan komt.
    pub calendar: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct AgendaResult {
    pub entries: Vec<AgendaEntry>,
    /// Wat niet gelezen kon worden, voor de gebruiker.
    pub problems: Vec<String>,
}

/// Werkuren voor vrije blokken, tenzij de gebruiker om een korter venster vroeg.
const DAY_START_HOUR: u32 = 8;
const DAY_END_HOUR: u32 = 19;

/// Het tijdvak van `check_availability`: `from` als datum is de hele dag, `to` hooguit 14 dagen later.
pub fn period(input: &Value) -> Result<(DateTime<Utc>, DateTime<Utc>), ConnectorError> {
    let from_text = super::text(input, "from").trim().to_string();
    let from = dates::parse(&from_text).ok_or_else(|| ConnectorError::new("from must be a date or ISO 8601 string."))?;
    let to_text = super::text(input, "to").trim().to_string();
    let mut to = dates::parse(&to_text);
    if to.is_some() && to_text.len() == 10 {
        // "to" als alleen een datum: die hele dag hoort erbij.
        to = to.map(|t| dates::add_days(t, 1));
    }
    let end = to.unwrap_or_else(|| dates::add_days(dates::start_of_day(from), 1));
    if end <= from {
        return Err(ConnectorError::new("to must be after from."));
    }
    Ok((from, end.min(from + Duration::days(14))))
}

/// Wat `check_availability` het model teruggeeft.
pub fn availability(
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    checked: &[String],
    entries: &[AgendaEntry],
    problems: &[String],
    skipped: &[String],
    has_feeds: bool,
) -> String {
    let mut lines = vec![format!("Period: {} to {}", dates::long(from), dates::long(to))];
    lines.push(if checked.is_empty() {
        "Checked: none (no calendar connected or access not granted).".into()
    } else {
        format!("Checked: {}.", checked.join("; "))
    });
    if !problems.is_empty() {
        lines.push(format!("Could not read: {}.", problems.join("; ")));
    }
    if !skipped.is_empty() {
        lines.push(format!("Not checked (disabled or no access): {}.", skipped.join(", ")));
    }
    let whole_days = to - from >= Duration::hours(20);
    let mut day = dates::start_of_day(from);
    let mut shown = 0;
    while day < to && shown < 14 {
        let next = dates::add_days(day, 1);
        shown += 1;
        let today: Vec<&AgendaEntry> =
            entries.iter().filter(|e| e.start < next && e.end.max(e.start + Duration::seconds(1)) > day).collect();
        let mut timed: Vec<&&AgendaEntry> = today.iter().filter(|e| !e.all_day && e.busy).collect();
        timed.sort_by_key(|e| e.start);
        let all_day: Vec<&&AgendaEntry> = today.iter().filter(|e| e.all_day).collect();
        let marked: Vec<&&AgendaEntry> = today.iter().filter(|e| !e.all_day && !e.busy).collect();
        lines.push(String::new());
        lines.push(format!("{}:", dates::day(day)));
        if today.is_empty() {
            lines.push("- no events in the checked calendars".into());
        }
        for e in timed.iter().take(30) {
            let place = if e.location.is_empty() { String::new() } else { format!(" | {}", short(&e.location, 40)) };
            lines.push(format!(
                "- busy {}–{} {} [{}]{place}",
                dates::time(e.start.max(day)),
                dates::time(e.end.min(next)),
                short(&e.title, 60),
                e.calendar
            ));
        }
        for e in all_day.iter().take(10) {
            lines.push(format!("- all day: {} [{}] (does not block automatically, judge for yourself)", short(&e.title, 60), e.calendar));
        }
        for e in marked.iter().take(10) {
            lines.push(format!("- marked as available: {} {} [{}]", dates::time(e.start), short(&e.title, 60), e.calendar));
        }
        let (window_start, window_end) = if whole_days {
            (dates::at_hour(day, DAY_START_HOUR).max(from), dates::at_hour(day, DAY_END_HOUR).min(to))
        } else {
            (from.max(day), to.min(next))
        };
        if window_end > window_start {
            let busy: Vec<AgendaEntry> = timed.iter().map(|e| (***e).clone()).collect();
            let free = free_slots(&busy, window_start, window_end);
            let label =
                if whole_days { format!("free ({}–{})", dates::time(window_start), dates::time(window_end)) } else { "free".into() };
            let slots = if free.is_empty() {
                "none".to_string()
            } else {
                free.iter().map(|(a, b)| format!("{}–{}", dates::time(*a), dates::time(*b))).collect::<Vec<_>>().join(", ")
            };
            lines.push(format!("- {label}: {slots}"));
        }
        day = next;
    }
    lines.push(String::new());
    lines.push(if has_feeds {
        "Is another calendar or app missing? Ask the user which one they use.".into()
    } else {
        "Note: this is everything Nook can access. Does the user also use another calendar (Google Calendar, Outlook, work calendar) not in the list above? Ask which one, and explain they can connect it under Settings › Accounts & connections › Other calendars using its ICS URL.".into()
    });
    lines.join("\n")
}

/// Gaten tussen afspraken binnen het venster, van een kwartier of langer.
pub fn free_slots(busy: &[AgendaEntry], from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<(DateTime<Utc>, DateTime<Utc>)> {
    let mut sorted: Vec<&AgendaEntry> = busy.iter().collect();
    sorted.sort_by_key(|e| e.start);
    let mut cursor = from;
    let mut slots = vec![];
    for e in sorted {
        if e.end <= cursor {
            continue;
        }
        if e.start >= to {
            break;
        }
        if e.start - cursor >= Duration::minutes(15) {
            slots.push((cursor, e.start));
        }
        cursor = cursor.max(e.end);
    }
    if to - cursor >= Duration::minutes(15) {
        slots.push((cursor, to));
    }
    slots
}

/// De afspraken in een tijdvak als regels voor het model (`list_events`).
pub fn event_lines(entries: &[AgendaEntry]) -> String {
    if entries.is_empty() {
        return "No events in this time range (or no calendar connected).".into();
    }
    entries
        .iter()
        .take(40)
        .map(|e| {
            let place = if e.location.is_empty() { String::new() } else { format!(" | {}", e.location) };
            let all_day = if e.all_day { " | all day" } else { "" };
            format!("{} | {} – {}{all_day}{place} | calendar {}", e.title, dates::iso(e.start), dates::iso(e.end), e.calendar)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(s: &str) -> DateTime<Utc> {
        dates::parse(s).unwrap()
    }

    fn entry(title: &str, start: &str, end: &str) -> AgendaEntry {
        AgendaEntry {
            title: title.into(),
            start: at(start),
            end: at(end),
            all_day: false,
            busy: true,
            location: String::new(),
            calendar: "Werk (ICS)".into(),
        }
    }

    #[test]
    fn free_slots_skip_short_gaps() {
        let busy = vec![entry("A", "2026-10-13T09:00", "2026-10-13T10:00"), entry("B", "2026-10-13T10:10", "2026-10-13T11:00")];
        let free = free_slots(&busy, at("2026-10-13T08:00"), at("2026-10-13T19:00"));
        let text: Vec<String> = free.iter().map(|(a, b)| format!("{}–{}", dates::time(*a), dates::time(*b))).collect();
        assert_eq!(text, ["08:00–09:00", "11:00–19:00"]);
    }

    #[test]
    fn availability_names_every_calendar() {
        let entries = vec![entry("Tandarts", "2026-10-13T13:00", "2026-10-13T14:00")];
        let text =
            availability(at("2026-10-13"), at("2026-10-14"), &["Werk (ICS)".into(), "Cal.com bookings".into()], &entries, &[], &[], true);
        assert!(text.contains("Checked: Werk (ICS); Cal.com bookings."));
        assert!(text.contains("dinsdag 13 oktober 2026:"));
        assert!(text.contains("- busy 13:00–14:00 Tandarts [Werk (ICS)]"));
        assert!(text.contains("- free (08:00–19:00): 08:00–13:00, 14:00–19:00"));
    }

    #[test]
    fn availability_without_calendars_asks_which_one() {
        let text = availability(at("2026-10-13"), at("2026-10-14"), &[], &[], &[], &[], false);
        assert!(text.contains("Checked: none"));
        assert!(text.contains("Other calendars using its ICS URL"));
    }

    #[test]
    fn period_from_a_date_is_the_whole_day() {
        let (from, to) = period(&serde_json::json!({"from": "2026-10-13"})).unwrap();
        assert_eq!(to - from, Duration::days(1));
        let (_, to2) = period(&serde_json::json!({"from": "2026-10-13", "to": "2026-10-14"})).unwrap();
        assert_eq!(to2 - from, Duration::days(2));
        let (_, capped) = period(&serde_json::json!({"from": "2026-10-13", "to": "2026-12-01"})).unwrap();
        assert_eq!(capped - from, Duration::days(14));
        assert!(period(&serde_json::json!({"from": "gisteren"})).is_err());
        assert!(period(&serde_json::json!({"from": "2026-10-13T10:00", "to": "2026-10-13T09:00"})).is_err());
    }
}
