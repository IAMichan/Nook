//! Eén blik op alle agenda's: agenda's via een ICS-adres en Cal.com (op de Mac ook Apple Agenda), zodat Nook "ben ik
//! 13 oktober beschikbaar?" kan beantwoorden zonder te vragen welke agenda.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{dates, short, ConnectorError};
use crate::brain::meeting_times;

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

fn json_number(input: &Value, key: &str) -> Option<f64> {
    if let Some(v) = input.get(key).and_then(|v| v.as_f64()) {
        return Some(v);
    }
    input.get(key).and_then(|v| v.as_str()).and_then(|s| s.trim().parse::<f64>().ok())
}

fn json_bool(input: &Value, key: &str) -> Option<bool> {
    if let Some(v) = input.get(key).and_then(|v| v.as_bool()) {
        return Some(v);
    }
    match input.get(key).and_then(|v| v.as_str()).map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("true") => Some(true),
        Some("false") => Some(false),
        _ => None,
    }
}

/// Parses `find_time` input into a `meeting_times::Request`, clamping bounds and defaulting to 60 min over 7 days.
pub fn find_time_request(input: &Value, now: DateTime<Utc>) -> Result<meeting_times::Request, ConnectorError> {
    let from_text = super::text(input, "from").trim().to_string();
    let to_text = super::text(input, "to").trim().to_string();
    let from = dates::parse(&from_text).unwrap_or(now).max(dates::start_of_day(now));
    let mut to = match dates::parse(&to_text) {
        Some(t) if to_text.len() == 10 => dates::add_days(t, 1),
        Some(t) => t,
        None => dates::add_days(from, 7),
    };
    to = to.min(from + Duration::days(meeting_times::MAX_DAYS));
    if to <= from {
        return Err(ConnectorError::new("to must be after from."));
    }

    let mins = json_number(input, "duration_minutes").unwrap_or(60.0).clamp(5.0, 12.0 * 60.0);
    let mut request = meeting_times::Request::new(from, to, Duration::seconds((mins * 60.0).round() as i64));
    request.count = json_number(input, "count").unwrap_or(3.0).round().max(1.0) as usize;
    if let Some(start) = meeting_times::minutes(input["day_start"].as_str()) {
        request.day_start = start;
    }
    if let Some(end) = meeting_times::minutes(input["day_end"].as_str()) {
        request.day_end = end;
    }
    if request.day_end <= request.day_start {
        request.day_end = (request.day_start + mins.round() as i32).min(24 * 60);
    }
    let buffer_mins = json_number(input, "buffer_minutes").unwrap_or(0.0).clamp(0.0, 120.0);
    request.buffer = Duration::seconds((buffer_mins * 60.0).round() as i64);
    request.weekends = json_bool(input, "weekends").unwrap_or(false);
    request.preference = meeting_times::Preference::from_text(input["prefer"].as_str());
    Ok(request)
}

/// Formats concrete free slots from `meeting_times::find` for `find_time`.
pub fn find_time(
    request: &meeting_times::Request,
    checked: &[String],
    entries: &[AgendaEntry],
    problems: &[String],
    now: DateTime<Utc>,
) -> String {
    // All-day items and events marked "free" do not block, as in check_availability.
    let busy: Vec<meeting_times::Busy> =
        entries.iter().filter(|e| !e.all_day && e.busy).map(|e| meeting_times::Busy { start: e.start, end: e.end }).collect();
    let slots = meeting_times::find(request, &busy, now);

    let clock = |v: i32| format!("{:02}:{:02}", v / 60, v % 60);
    let mins = request.duration.num_minutes();
    let buf_mins = request.buffer.num_minutes();
    let mut header = format!(
        "Looking for {mins} minutes between {} and {}, {}–{}",
        dates::long(request.from),
        dates::long(request.to),
        clock(request.day_start),
        clock(request.day_end)
    );
    if !request.weekends {
        header.push_str(", weekdays only");
    }
    if buf_mins > 0 {
        header.push_str(&format!(", {buf_mins} minutes buffer around other appointments"));
    }
    if request.preference != meeting_times::Preference::Any {
        header.push_str(&format!(", {} first", request.preference.as_str()));
    }
    header.push('.');

    let mut lines = vec![header];
    lines.push(if checked.is_empty() {
        "Checked: none (no calendar connected or access not granted): these times are not checked against anything.".into()
    } else {
        format!("Checked: {}.", checked.join("; "))
    });
    if !problems.is_empty() {
        lines.push(format!("Could not read: {}.", problems.join("; ")));
    }
    if slots.is_empty() {
        lines.push(
            "No free time of that length in this window. Offer a longer period, other hours, the weekend or a shorter duration.".into(),
        );
    } else {
        lines.push("Options:".into());
        for (index, slot) in slots.iter().enumerate() {
            lines.push(format!(
                "{}. {} {}–{} | start {} | end {}",
                index + 1,
                dates::day(slot.start),
                dates::time(slot.start),
                dates::time(slot.end),
                dates::iso(slot.start),
                dates::iso(slot.end)
            ));
        }
        let all_day: Vec<&AgendaEntry> = entries.iter().filter(|e| e.all_day).collect();
        if !all_day.is_empty() {
            lines.push(format!(
                "All-day items in this period (they do not block, judge for yourself): {}.",
                all_day.iter().take(6).map(|e| format!("{} {}", dates::day(e.start), short(&e.title, 60))).collect::<Vec<_>>().join("; ")
            ));
        }
        lines.push(
            "Give the options as a short list the user can pick from (or take the first when they asked you to just plan it).".into(),
        );
    }
    lines.join("\n")
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

    #[test]
    fn find_time_request_reads_options_and_clamps() {
        let now = at("2026-11-16T08:00");
        let req = find_time_request(
            &serde_json::json!({
                "duration_minutes": 45,
                "from": "2026-11-16",
                "to": "2026-11-18",
                "count": 2,
                "day_start": "10:00",
                "day_end": "16:00",
                "prefer": "afternoon",
                "buffer_minutes": 15,
                "weekends": true
            }),
            now,
        )
        .unwrap();
        assert_eq!(req.duration, Duration::minutes(45));
        assert_eq!(req.from, at("2026-11-16T00:00"));
        assert_eq!(req.to, at("2026-11-19T00:00"));
        assert_eq!(req.count, 2);
        assert_eq!(req.day_start, 600);
        assert_eq!(req.day_end, 960);
        assert_eq!(req.preference, meeting_times::Preference::Afternoon);
        assert_eq!(req.buffer, Duration::minutes(15));
        assert!(req.weekends);

        // Inverted window fails.
        assert!(find_time_request(&serde_json::json!({"from": "2026-11-18", "to": "2026-11-17"}), now).is_err());
    }

    #[test]
    fn find_time_formats_options_and_ignores_free_and_all_day() {
        let now = at("2026-11-16T08:00");
        let req = find_time_request(
            &serde_json::json!({
                "duration_minutes": 60,
                "from": "2026-11-16",
                "to": "2026-11-16",
                "count": 2,
                "prefer": "morning",
                "buffer_minutes": 15
            }),
            now,
        )
        .unwrap();
        let mut free_entry = entry("Tentative", "2026-11-16T09:00", "2026-11-16T10:00");
        free_entry.busy = false;
        let mut all_day_entry = entry("Conference", "2026-11-16T00:00", "2026-11-17T00:00");
        all_day_entry.all_day = true;
        let busy_entry = entry("Standup", "2026-11-16T09:00", "2026-11-16T09:30");

        let out = find_time(&req, &["Werk (ICS)".into()], &[free_entry, all_day_entry, busy_entry], &[], now);
        assert!(out.contains("Looking for 60 minutes"), "{out}");
        assert!(out.contains("weekdays only, 15 minutes buffer around other appointments, morning first."), "{out}");
        assert!(out.contains("Checked: Werk (ICS)."), "{out}");
        // Busy 09:00-09:30 + 15m buffer blocks until 09:45; first option starts 09:45-10:45.
        assert!(out.contains("1. maandag 16 november 2026 09:45–10:45 | start "), "{out}");
        assert!(
            out.contains("All-day items in this period (they do not block, judge for yourself): maandag 16 november 2026 Conference."),
            "{out}"
        );
    }
}
