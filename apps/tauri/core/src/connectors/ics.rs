//! Agenda's in ICS-formaat (RFC 5545): Google Agenda, Outlook, iCloud, Fastmail, Proton en Cal.com. Geen netwerk hier:
//! tekst erin, afspraken eruit, herhalingen (RRULE) uitgerold, uitzonderingen (EXDATE, RECURRENCE-ID) meegenomen.

use std::collections::HashSet;

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike, Utc, Weekday};
use chrono_tz::Tz;

use super::agenda::AgendaEntry;

/// De tijdzone van een afspraak: die van deze computer, of een benoemde zone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
    Local,
    Named(Tz),
}

impl Zone {
    fn naive(self, date: DateTime<Utc>) -> NaiveDateTime {
        match self {
            Zone::Local => date.with_timezone(&Local).naive_local(),
            Zone::Named(tz) => date.with_timezone(&tz).naive_local(),
        }
    }

    /// Een kloktijd in deze zone; valt hij in een zomertijdgat, dan het uur erna.
    fn resolve(self, naive: NaiveDateTime) -> Option<DateTime<Utc>> {
        fn pick<T: TimeZone>(tz: &T, n: NaiveDateTime) -> Option<DateTime<Utc>> {
            tz.from_local_datetime(&n)
                .earliest()
                .or_else(|| tz.from_local_datetime(&(n + Duration::hours(1))).earliest())
                .map(|d| d.with_timezone(&Utc))
        }
        match self {
            Zone::Local => pick(&Local, naive),
            Zone::Named(tz) => pick(&tz, naive),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Frequency {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Rule {
    pub frequency: Frequency,
    pub interval: i64,
    pub count: Option<usize>,
    pub until: Option<DateTime<Utc>>,
    /// Rangnummer 0 = elke.
    pub by_day: Vec<(i32, Weekday)>,
    pub by_month_day: Vec<i32>,
    pub by_month: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub uid: String,
    pub title: String,
    pub location: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub all_day: bool,
    pub busy: bool,
    pub zone: Zone,
    pub rule: Option<Rule>,
    pub exceptions: HashSet<DateTime<Utc>>,
    /// Bij een los aangepaste herhaling: de oorspronkelijke begintijd van die keer.
    pub recurrence_id: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Default)]
pub struct Calendar {
    pub name: Option<String>,
    pub events: Vec<Event>,
}

struct Line {
    name: String,
    params: Vec<(String, String)>,
    value: String,
}

impl Line {
    fn param(&self, key: &str) -> Option<&str> {
        self.params.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}

const CAP: usize = 4_000;

impl Calendar {
    pub fn parse(text: &str) -> Self {
        let mut name = None;
        let mut events = vec![];
        let mut current: Option<Vec<Line>> = None;
        let mut nested = 0;
        for raw in unfold(text) {
            let Some(line) = parse_line(&raw) else { continue };
            if line.name == "BEGIN" {
                if line.value.eq_ignore_ascii_case("VEVENT") {
                    current = Some(vec![]);
                    nested = 0;
                } else if current.is_some() {
                    nested += 1;
                }
                continue;
            }
            if line.name == "END" {
                if line.value.eq_ignore_ascii_case("VEVENT") {
                    if let Some(event) = current.take().and_then(|lines| make_event(&lines)) {
                        events.push(event);
                    }
                } else if current.is_some() && nested > 0 {
                    nested -= 1;
                }
                continue;
            }
            match &mut current {
                Some(lines) if nested == 0 => lines.push(line),
                Some(_) => {}
                None if line.name == "X-WR-CALNAME" && name.is_none() => name = Some(unescape(&line.value)),
                None => {}
            }
        }
        Self { name, events }
    }

    /// Alle afspraken die (deels) in het tijdvak vallen, herhalingen uitgerold.
    pub fn entries(&self, from: DateTime<Utc>, to: DateTime<Utc>, label: &str) -> Vec<AgendaEntry> {
        let overridden: HashSet<(String, DateTime<Utc>)> =
            self.events.iter().filter_map(|e| e.recurrence_id.map(|r| (e.uid.clone(), r))).collect();
        let mut out = vec![];
        let mut add = |event: &Event, start: DateTime<Utc>, end: DateTime<Utc>| {
            if start < to && end.max(start + Duration::seconds(1)) > from {
                out.push(AgendaEntry {
                    title: event.title.clone(),
                    start,
                    end,
                    all_day: event.all_day,
                    busy: event.busy,
                    location: event.location.clone(),
                    calendar: label.to_string(),
                });
            }
        };
        for event in &self.events {
            let length = (event.end - event.start).max(Duration::zero());
            match (&event.rule, event.recurrence_id) {
                (Some(rule), None) => {
                    let days = ((length.num_seconds() as f64 / 86_400.0).round() as i64).max(1);
                    for start in starts(event, rule, to) {
                        if overridden.contains(&(event.uid.clone(), start)) {
                            continue;
                        }
                        let end = if event.all_day {
                            event.zone.resolve(event.zone.naive(start) + Duration::days(days)).unwrap_or(start + length)
                        } else {
                            start + length
                        };
                        add(event, start, end);
                    }
                }
                _ => add(event, event.start, event.end),
            }
        }
        out.sort_by_key(|e| e.start);
        out
    }
}

/// Regels die in het bestand afgebroken zijn (beginnen met een spatie of tab) weer aan elkaar.
fn unfold(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = vec![];
    for raw in text.split(['\n', '\r']) {
        if raw.is_empty() {
            continue;
        }
        if (raw.starts_with(' ') || raw.starts_with('\t')) && !lines.is_empty() {
            let last = lines.len() - 1;
            lines[last].push_str(&raw[1..]);
        } else {
            lines.push(raw.to_string());
        }
    }
    lines
}

fn parse_line(line: &str) -> Option<Line> {
    let mut in_quotes = false;
    let mut colon = None;
    for (i, c) in line.char_indices() {
        if c == '"' {
            in_quotes = !in_quotes;
        } else if c == ':' && !in_quotes {
            colon = Some(i);
            break;
        }
    }
    let colon = colon?;
    let head = &line[..colon];
    let value = line[colon + 1..].to_string();
    let mut parts = vec![];
    let mut piece = String::new();
    let mut quoted = false;
    for c in head.chars() {
        if c == '"' {
            quoted = !quoted;
            piece.push(c);
        } else if c == ';' && !quoted {
            parts.push(std::mem::take(&mut piece));
        } else {
            piece.push(c);
        }
    }
    parts.push(piece);
    let params =
        parts[1..].iter().filter_map(|p| p.split_once('=').map(|(k, v)| (k.to_uppercase(), v.trim_matches('"').to_string()))).collect();
    Some(Line { name: parts[0].to_uppercase(), params, value })
}

fn unescape(text: &str) -> String {
    text.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")
}

/// Outlook gebruikt Windows-namen voor tijdzones.
fn windows_zone(name: &str) -> Option<&'static str> {
    Some(match name {
        "W. Europe Standard Time" => "Europe/Amsterdam",
        "Romance Standard Time" => "Europe/Paris",
        "Central Europe Standard Time" => "Europe/Budapest",
        "Central European Standard Time" => "Europe/Warsaw",
        "GMT Standard Time" => "Europe/London",
        "E. Europe Standard Time" => "Europe/Bucharest",
        "Eastern Standard Time" => "America/New_York",
        "Central Standard Time" => "America/Chicago",
        "Mountain Standard Time" => "America/Denver",
        "Pacific Standard Time" => "America/Los_Angeles",
        "UTC" => "UTC",
        _ => return None,
    })
}

fn zone_named(name: Option<&str>) -> Zone {
    let Some(name) = name.filter(|n| !n.is_empty()) else { return Zone::Local };
    if let Ok(tz) = name.parse::<Tz>() {
        return Zone::Named(tz);
    }
    windows_zone(name).and_then(|m| m.parse::<Tz>().ok()).map(Zone::Named).unwrap_or(Zone::Local)
}

fn parse_date(value: &str, params: &Line) -> Option<(DateTime<Utc>, bool, Zone)> {
    parse_date_with(value.trim(), params.param("VALUE"), params.param("TZID"))
}

fn parse_date_with(value: &str, kind: Option<&str>, tzid: Option<&str>) -> Option<(DateTime<Utc>, bool, Zone)> {
    if value.len() < 8 || !value.is_char_boundary(8) {
        return None;
    }
    let year: i32 = value[..4].parse().ok()?;
    let month: u32 = value[4..6].parse().ok()?;
    let day: u32 = value[6..8].parse().ok()?;
    let all_day = kind == Some("DATE") || value.len() == 8;
    let date = NaiveDate::from_ymd_opt(year, month, day)?;
    let mut zone = Zone::Local;
    let mut time = NaiveTime::MIN;
    if !all_day && value.len() >= 15 {
        let num = |a: usize, b: usize| value.get(a..b).and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
        time = NaiveTime::from_hms_opt(num(9, 11), num(11, 13), num(13, 15)).unwrap_or(NaiveTime::MIN);
        zone = if value.ends_with('Z') { Zone::Named(Tz::UTC) } else { zone_named(tzid) };
    }
    let resolved = zone.resolve(date.and_time(time))?;
    Some((resolved, all_day, zone))
}

/// "PT1H30M", "P1D", "P1W"
fn parse_duration(value: &str) -> Option<Duration> {
    let mut text = value.trim().to_uppercase();
    let mut sign = 1;
    if let Some(rest) = text.strip_prefix('-') {
        sign = -1;
        text = rest.to_string();
    }
    if let Some(rest) = text.strip_prefix('+') {
        text = rest.to_string();
    }
    let text = text.strip_prefix('P')?;
    let mut total = 0i64;
    let mut number = String::new();
    let mut in_time = false;
    for c in text.chars() {
        if c == 'T' {
            in_time = true;
            continue;
        }
        if c.is_ascii_digit() {
            number.push(c);
            continue;
        }
        let amount: i64 = number.parse().ok()?;
        number.clear();
        total += match c {
            'W' => amount * 7 * 86_400,
            'D' => amount * 86_400,
            'H' => amount * 3_600,
            'M' if in_time => amount * 60,
            'M' => 0,
            'S' => amount,
            _ => return None,
        };
    }
    Some(Duration::seconds(sign * total))
}

fn make_event(lines: &[Line]) -> Option<Event> {
    let first = |name: &str| lines.iter().find(|l| l.name == name);
    if first("STATUS").map(|l| l.value.trim().eq_ignore_ascii_case("CANCELLED")).unwrap_or(false) {
        return None;
    }
    let start_line = first("DTSTART")?;
    let (start, all_day, zone) = parse_date(&start_line.value, start_line)?;
    let end = if let Some((end, _, _)) = first("DTEND").and_then(|l| parse_date(&l.value, l)) {
        end
    } else if let Some(d) = first("DURATION").and_then(|l| parse_duration(&l.value)) {
        start + d
    } else if all_day {
        start + Duration::days(1)
    } else {
        start
    };
    let mut busy = !first("TRANSP").map(|l| l.value.trim().eq_ignore_ascii_case("TRANSPARENT")).unwrap_or(false);
    if first("X-MICROSOFT-CDO-BUSYSTATUS").map(|l| l.value.trim().eq_ignore_ascii_case("FREE")).unwrap_or(false) {
        busy = false;
    }
    let mut exceptions = HashSet::new();
    for line in lines.iter().filter(|l| l.name == "EXDATE") {
        for part in line.value.split(',') {
            let kind = line.param("VALUE").or(if part.trim().len() == 8 { Some("DATE") } else { None });
            if let Some((d, _, _)) = parse_date_with(part.trim(), kind, line.param("TZID")) {
                exceptions.insert(d);
            }
        }
    }
    Some(Event {
        uid: first("UID").map(|l| l.value.trim().to_string()).unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
        title: first("SUMMARY").map(|l| unescape(&l.value)).unwrap_or_else(|| "Untitled".into()),
        location: first("LOCATION").map(|l| unescape(&l.value)).unwrap_or_default(),
        start,
        end,
        all_day,
        busy,
        zone,
        rule: first("RRULE").and_then(|l| parse_rule(&l.value, zone)),
        exceptions,
        recurrence_id: first("RECURRENCE-ID").and_then(|l| parse_date(&l.value, l)).map(|(d, _, _)| d),
    })
}

fn weekday(code: &str) -> Option<Weekday> {
    Some(match code {
        "SU" => Weekday::Sun,
        "MO" => Weekday::Mon,
        "TU" => Weekday::Tue,
        "WE" => Weekday::Wed,
        "TH" => Weekday::Thu,
        "FR" => Weekday::Fri,
        "SA" => Weekday::Sat,
        _ => return None,
    })
}

fn parse_rule(value: &str, zone: Zone) -> Option<Rule> {
    let parts: Vec<(String, String)> =
        value.split(';').filter_map(|p| p.split_once('=').map(|(k, v)| (k.trim().to_uppercase(), v.trim().to_string()))).collect();
    let get = |k: &str| parts.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str());
    let frequency = match get("FREQ")?.to_uppercase().as_str() {
        "DAILY" => Frequency::Daily,
        "WEEKLY" => Frequency::Weekly,
        "MONTHLY" => Frequency::Monthly,
        "YEARLY" => Frequency::Yearly,
        _ => return None,
    };
    let mut rule = Rule {
        frequency,
        interval: get("INTERVAL").and_then(|v| v.parse().ok()).unwrap_or(1).max(1),
        count: get("COUNT").and_then(|v| v.parse().ok()),
        until: None,
        by_day: vec![],
        by_month_day: vec![],
        by_month: vec![],
    };
    if let Some(until) = get("UNTIL") {
        let tzid = match zone {
            Zone::Named(tz) => Some(tz.name().to_string()),
            Zone::Local => None,
        };
        let kind = (until.len() == 8).then_some("DATE");
        if let Some((d, _, _)) = parse_date_with(until, kind, tzid.as_deref()) {
            // Een UNTIL zonder tijd geldt tot het eind van die dag.
            rule.until = Some(if until.len() == 8 { d + Duration::seconds(86_399) } else { d });
        }
    }
    for item in get("BYDAY").unwrap_or("").split(',') {
        let text = item.trim().to_uppercase();
        if text.len() < 2 || !text.is_char_boundary(text.len() - 2) {
            continue;
        }
        let Some(day) = weekday(&text[text.len() - 2..]) else { continue };
        let ordinal = text[..text.len() - 2].parse().unwrap_or(0);
        rule.by_day.push((ordinal, day));
    }
    rule.by_month_day = get("BYMONTHDAY").unwrap_or("").split(',').filter_map(|v| v.trim().parse().ok()).collect();
    rule.by_month = get("BYMONTH").unwrap_or("").split(',').filter_map(|v| v.trim().parse().ok()).collect();
    Some(rule)
}

fn days_in_month(year: i32, month: u32) -> u32 {
    let (ny, nm) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    NaiveDate::from_ymd_opt(ny, nm, 1).and_then(|d| d.pred_opt()).map(|d| d.day()).unwrap_or(30)
}

/// Alle begintijden van een herhalende afspraak tot `limit`.
fn starts(event: &Event, rule: &Rule, limit: DateTime<Utc>) -> Vec<DateTime<Utc>> {
    let zone = event.zone;
    let local_start = zone.naive(event.start);
    let time = local_start.time();
    let mut result = vec![];
    let mut produced = 0usize;

    // Geeft false als het uitrollen moet stoppen.
    let mut emit = |date: DateTime<Utc>, result: &mut Vec<DateTime<Utc>>| -> bool {
        if date < event.start {
            return true;
        }
        if date > limit {
            return false;
        }
        if rule.until.is_some_and(|u| date > u) {
            return false;
        }
        if rule.count.is_some_and(|c| produced >= c) {
            return false;
        }
        produced += 1;
        if !event.exceptions.contains(&date) {
            result.push(date);
        }
        produced < CAP
    };
    let at = |date: NaiveDate| zone.resolve(date.and_time(time));

    match rule.frequency {
        Frequency::Daily => {
            for index in 0..CAP as i64 {
                let Some(date) = at(local_start.date() + Duration::days(index * rule.interval)) else { break };
                if !rule.by_day.is_empty() && !rule.by_day.iter().any(|(_, d)| *d == zone.naive(date).weekday()) {
                    if date > limit {
                        break;
                    }
                    continue;
                }
                if !emit(date, &mut result) {
                    break;
                }
            }
        }
        Frequency::Weekly => {
            let wanted: Vec<Weekday> =
                if rule.by_day.is_empty() { vec![local_start.weekday()] } else { rule.by_day.iter().map(|(_, d)| *d).collect() };
            let mut offsets: Vec<i64> = wanted.iter().map(|d| d.num_days_from_monday() as i64).collect();
            offsets.sort_unstable();
            offsets.dedup();
            let week_start = local_start.date() - Duration::days(local_start.weekday().num_days_from_monday() as i64);
            'outer: for week in 0..CAP as i64 {
                let base = week_start + Duration::days(7 * week * rule.interval);
                match zone.resolve(base.and_time(NaiveTime::MIN)) {
                    Some(b) if b > limit => break,
                    None => break,
                    _ => {}
                }
                for offset in &offsets {
                    let Some(date) = at(base + Duration::days(*offset)) else { continue };
                    if date < event.start {
                        continue;
                    }
                    if !emit(date, &mut result) {
                        break 'outer;
                    }
                }
            }
        }
        Frequency::Monthly | Frequency::Yearly => {
            let (start_year, start_month, start_day) = (local_start.year(), local_start.month(), local_start.day());
            let dates = |year: i32, month: u32| -> Vec<DateTime<Utc>> {
                let days = days_in_month(year, month) as i32;
                let mut found: Vec<i32> = vec![];
                if !rule.by_month_day.is_empty() {
                    for value in &rule.by_month_day {
                        let number = if *value > 0 { *value } else { days + 1 + value };
                        if (1..=days).contains(&number) {
                            found.push(number);
                        }
                    }
                } else if !rule.by_day.is_empty() {
                    for (ordinal, day) in &rule.by_day {
                        let matching: Vec<i32> = (1..=days)
                            .filter(|n| NaiveDate::from_ymd_opt(year, month, *n as u32).map(|d| d.weekday() == *day).unwrap_or(false))
                            .collect();
                        let count = matching.len() as i32;
                        if *ordinal == 0 {
                            found.extend(&matching);
                        } else if *ordinal > 0 && *ordinal <= count {
                            found.push(matching[(*ordinal - 1) as usize]);
                        } else if *ordinal < 0 && -*ordinal <= count {
                            found.push(matching[(count + *ordinal) as usize]);
                        }
                    }
                } else {
                    found.push(start_day as i32);
                }
                found.sort_unstable();
                found.dedup();
                found.into_iter().filter_map(|n| NaiveDate::from_ymd_opt(year, month, n as u32)).filter_map(at).collect()
            };
            'outer: for step in 0..CAP as i64 {
                let months: Vec<(i32, u32)> = if rule.frequency == Frequency::Monthly {
                    let total = (start_month as i64 - 1) + step * rule.interval;
                    vec![(start_year + (total / 12) as i32, (total % 12) as u32 + 1)]
                } else {
                    let year = start_year + (step * rule.interval) as i32;
                    let mut list = if rule.by_month.is_empty() { vec![start_month] } else { rule.by_month.clone() };
                    list.sort_unstable();
                    list.into_iter().map(|m| (year, m)).collect()
                };
                for (year, month) in months {
                    let Some(first) = NaiveDate::from_ymd_opt(year, month, 1).and_then(|d| zone.resolve(d.and_time(NaiveTime::MIN))) else {
                        continue;
                    };
                    if first > limit {
                        break 'outer;
                    }
                    for date in dates(year, month) {
                        if !emit(date, &mut result) {
                            break 'outer;
                        }
                    }
                }
            }
        }
    }
    let _ = time.hour();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn cal(body: &str) -> Calendar {
        Calendar::parse(&format!("BEGIN:VCALENDAR\r\nX-WR-CALNAME:Werk\r\n{body}\r\nEND:VCALENDAR\r\n"))
    }

    #[test]
    fn parses_a_simple_event_with_folding_and_escapes() {
        let c = cal("BEGIN:VEVENT\r\nUID:1\r\nSUMMARY:Overleg\\, kwartaal\r\nLOCATION:Kamer\r\n  3\r\nDTSTART:20261013T090000Z\r\nDTEND:20261013T100000Z\r\nEND:VEVENT");
        assert_eq!(c.name.as_deref(), Some("Werk"));
        let e = &c.events[0];
        assert_eq!(e.title, "Overleg, kwartaal");
        assert_eq!(e.location, "Kamer 3");
        assert_eq!(e.start, utc("2026-10-13T09:00:00Z"));
        assert_eq!(e.end, utc("2026-10-13T10:00:00Z"));
        assert!(e.busy);
    }

    #[test]
    fn time_zones_windows_names_and_all_day() {
        let c = cal(
            "BEGIN:VEVENT\nUID:a\nSUMMARY:A\nDTSTART;TZID=Europe/Amsterdam:20261013T090000\nDURATION:PT1H30M\nEND:VEVENT\n\
             BEGIN:VEVENT\nUID:b\nSUMMARY:B\nDTSTART;TZID=W. Europe Standard Time:20260701T090000\nDTEND;TZID=W. Europe Standard Time:20260701T100000\nEND:VEVENT\n\
             BEGIN:VEVENT\nUID:c\nSUMMARY:C\nDTSTART;VALUE=DATE:20261013\nTRANSP:TRANSPARENT\nEND:VEVENT",
        );
        assert_eq!(c.events[0].start, utc("2026-10-13T07:00:00Z"));
        assert_eq!(c.events[0].end, utc("2026-10-13T08:30:00Z"));
        assert_eq!(c.events[1].start, utc("2026-07-01T07:00:00Z"));
        let all_day = &c.events[2];
        assert!(all_day.all_day);
        assert!(!all_day.busy);
        assert_eq!(all_day.end - all_day.start, Duration::days(1));
    }

    #[test]
    fn cancelled_and_nested_alarms_are_handled() {
        let c = cal("BEGIN:VEVENT\nUID:x\nSUMMARY:Weg\nSTATUS:CANCELLED\nDTSTART:20261013T090000Z\nEND:VEVENT\n\
             BEGIN:VEVENT\nUID:y\nSUMMARY:Blijft\nDTSTART:20261013T090000Z\nBEGIN:VALARM\nSUMMARY:Alarm\nEND:VALARM\nEND:VEVENT");
        assert_eq!(c.events.len(), 1);
        assert_eq!(c.events[0].title, "Blijft");
    }

    #[test]
    fn weekly_rule_with_exception_and_override() {
        let c = cal(
            "BEGIN:VEVENT\nUID:w\nSUMMARY:Standup\nDTSTART;TZID=Europe/Amsterdam:20261005T093000\nDTEND;TZID=Europe/Amsterdam:20261005T094500\n\
             RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6\nEXDATE;TZID=Europe/Amsterdam:20261007T093000\nEND:VEVENT\n\
             BEGIN:VEVENT\nUID:w\nSUMMARY:Standup (later)\nRECURRENCE-ID;TZID=Europe/Amsterdam:20261012T093000\n\
             DTSTART;TZID=Europe/Amsterdam:20261012T110000\nDTEND;TZID=Europe/Amsterdam:20261012T111500\nEND:VEVENT",
        );
        let list = c.entries(utc("2026-10-01T00:00:00Z"), utc("2026-11-01T00:00:00Z"), "Werk");
        let titles: Vec<(String, String)> = list.iter().map(|e| (e.title.clone(), e.start.to_rfc3339())).collect();
        assert_eq!(
            titles,
            vec![
                ("Standup".into(), "2026-10-05T07:30:00+00:00".into()),
                // 7 oktober is uitgezonderd; 12 oktober is verplaatst.
                ("Standup (later)".into(), "2026-10-12T09:00:00+00:00".into()),
                ("Standup".into(), "2026-10-14T07:30:00+00:00".into()),
                ("Standup".into(), "2026-10-19T07:30:00+00:00".into()),
                ("Standup".into(), "2026-10-21T07:30:00+00:00".into()),
            ]
        );
        assert!(list.iter().all(|e| e.calendar == "Werk"));
    }

    #[test]
    fn weekly_rule_keeps_local_time_across_dst() {
        let c = cal("BEGIN:VEVENT\nUID:d\nSUMMARY:Sport\nDTSTART;TZID=Europe/Amsterdam:20261019T190000\nDTEND;TZID=Europe/Amsterdam:20261019T200000\nRRULE:FREQ=WEEKLY\nEND:VEVENT");
        let list = c.entries(utc("2026-10-19T00:00:00Z"), utc("2026-11-03T00:00:00Z"), "x");
        assert_eq!(list[0].start, utc("2026-10-19T17:00:00Z"));
        // Na 25 oktober is het wintertijd: 19:00 is dan 18:00 UTC.
        assert_eq!(list[1].start, utc("2026-10-26T18:00:00Z"));
    }

    #[test]
    fn monthly_by_day_and_month_day_and_until() {
        let c = cal(
            "BEGIN:VEVENT\nUID:m\nSUMMARY:Laatste vrijdag\nDTSTART:20261030T150000Z\nDTEND:20261030T160000Z\nRRULE:FREQ=MONTHLY;BYDAY=-1FR\nEND:VEVENT\n\
             BEGIN:VEVENT\nUID:n\nSUMMARY:Huur\nDTSTART;VALUE=DATE:20261031\nRRULE:FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20261231\nEND:VEVENT",
        );
        let list = c.entries(utc("2026-10-01T00:00:00Z"), utc("2027-02-01T00:00:00Z"), "x");
        let fridays: Vec<String> =
            list.iter().filter(|e| e.title == "Laatste vrijdag").map(|e| e.start.format("%Y-%m-%d").to_string()).collect();
        assert_eq!(fridays, ["2026-10-30", "2026-11-27", "2026-12-25", "2027-01-29"]);
        let rent = list.iter().filter(|e| e.title == "Huur").count();
        assert_eq!(rent, 3, "oct, nov, dec; until stops january");
    }

    #[test]
    fn yearly_and_daily_with_interval() {
        let c = cal(
            "BEGIN:VEVENT\nUID:y\nSUMMARY:Verjaardag\nDTSTART;VALUE=DATE:20200229\nRRULE:FREQ=YEARLY\nEND:VEVENT\n\
             BEGIN:VEVENT\nUID:z\nSUMMARY:Om de dag\nDTSTART:20261001T080000Z\nDTEND:20261001T081500Z\nRRULE:FREQ=DAILY;INTERVAL=2;COUNT=3\nEND:VEVENT",
        );
        let list = c.entries(utc("2026-01-01T00:00:00Z"), utc("2029-01-01T00:00:00Z"), "x");
        let birthdays = list.iter().filter(|e| e.title == "Verjaardag").count();
        assert_eq!(birthdays, 1, "29 februari bestaat alleen in 2028");
        let days: Vec<String> = list.iter().filter(|e| e.title == "Om de dag").map(|e| e.start.format("%d").to_string()).collect();
        assert_eq!(days, ["01", "03", "05"]);
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("PT1H30M"), Some(Duration::minutes(90)));
        assert_eq!(parse_duration("P1D"), Some(Duration::days(1)));
        assert_eq!(parse_duration("P1W"), Some(Duration::days(7)));
        assert_eq!(parse_duration("-PT15M"), Some(Duration::minutes(-15)));
        assert_eq!(parse_duration("1H"), None);
    }
}
