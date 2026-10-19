//! Datums zoals de koppelingen ze tonen en lezen (`NookDates` op de Mac): ISO 8601 met of zonder tijdzone in, korte
//! Nederlandse notaties uit ("vr 16 okt 14:00", "woensdag 14 oktober 2026").

use chrono::{DateTime, Datelike, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};

const WEEKDAYS: [&str; 7] = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"];
const WEEKDAYS_SHORT: [&str; 7] = ["ma", "di", "wo", "do", "vr", "za", "zo"];
const MONTHS: [&str; 12] =
    ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"];
const MONTHS_SHORT: [&str; 12] = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"];

/// ISO 8601 met of zonder tijdzone; zonder zone telt de tijdzone van deze computer. Ook alleen een datum (`2027-10-13`).
pub fn parse(text: &str) -> Option<DateTime<Utc>> {
    let t = text.trim();
    if let Ok(d) = DateTime::parse_from_rfc3339(t) {
        return Some(d.with_timezone(&Utc));
    }
    // "2026-10-18T12:00:00+0200" en "… 12:00:00Z" zonder T.
    for f in ["%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M%z", "%Y-%m-%d %H:%M:%S%z"] {
        if let Ok(d) = DateTime::parse_from_str(t, f) {
            return Some(d.with_timezone(&Utc));
        }
    }
    for f in ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"] {
        if let Ok(n) = NaiveDateTime::parse_from_str(t, f) {
            return local(n);
        }
    }
    let n = NaiveDate::parse_from_str(t, "%Y-%m-%d").ok()?;
    local(n.and_hms_opt(0, 0, 0)?)
}

fn local(n: NaiveDateTime) -> Option<DateTime<Utc>> {
    Local.from_local_datetime(&n).earliest().map(|d| d.with_timezone(&Utc))
}

/// "2026-10-14T08:31:00+02:00", in de tijdzone van deze computer.
pub fn iso(date: DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

/// "vr 16 okt 14:00"
pub fn short(date: DateTime<Utc>) -> String {
    let d = date.with_timezone(&Local);
    format!(
        "{} {} {} {}",
        WEEKDAYS_SHORT[d.weekday().num_days_from_monday() as usize],
        d.day(),
        MONTHS_SHORT[d.month0() as usize],
        d.format("%H:%M")
    )
}

/// "14:00"
pub fn time(date: DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%H:%M").to_string()
}

/// "woensdag 14 oktober 2026"
pub fn day(date: DateTime<Utc>) -> String {
    let d = date.with_timezone(&Local);
    format!("{} {} {} {}", WEEKDAYS[d.weekday().num_days_from_monday() as usize], d.day(), MONTHS[d.month0() as usize], d.year())
}

/// "woensdag 14 oktober 2026 08:31"
pub fn long(date: DateTime<Utc>) -> String {
    format!("{} {}", day(date), time(date))
}

/// "zojuist", "5 min geleden", "vandaag om 14:02", "gisteren om 09:10", anders "vr 16 okt".
pub fn ago(date: DateTime<Utc>) -> String {
    ago_from(date, Utc::now())
}

pub fn ago_from(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (now - date).num_seconds();
    if seconds < 60 {
        return "zojuist".into();
    }
    if seconds < 3600 {
        return format!("{} min geleden", seconds / 60);
    }
    let (d, n) = (date.with_timezone(&Local), now.with_timezone(&Local));
    if d.date_naive() == n.date_naive() {
        return format!("vandaag om {}", d.format("%H:%M"));
    }
    if n.date_naive().pred_opt() == Some(d.date_naive()) {
        return format!("gisteren om {}", d.format("%H:%M"));
    }
    format!("{} {} {}", WEEKDAYS_SHORT[d.weekday().num_days_from_monday() as usize], d.day(), MONTHS_SHORT[d.month0() as usize])
}

/// Begin van de dag (lokaal) waarin `date` valt.
pub fn start_of_day(date: DateTime<Utc>) -> DateTime<Utc> {
    let d = date.with_timezone(&Local).date_naive();
    local(d.and_hms_opt(0, 0, 0).unwrap_or_default()).unwrap_or(date)
}

/// Dezelfde kloktijd `days` dagen later (lokaal, dus ook over een zomertijdwissel).
pub fn add_days(date: DateTime<Utc>, days: i64) -> DateTime<Utc> {
    let d = date.with_timezone(&Local).naive_local() + chrono::Duration::days(days);
    local(d).unwrap_or(date + chrono::Duration::days(days))
}

/// Dezelfde dag om dit uur (lokaal).
pub fn at_hour(day: DateTime<Utc>, hour: u32) -> DateTime<Utc> {
    let d = day.with_timezone(&Local).date_naive();
    d.and_hms_opt(hour, 0, 0).and_then(local).unwrap_or(day)
}

pub fn is_today(date: DateTime<Utc>) -> bool {
    date.with_timezone(&Local).date_naive() == Local::now().date_naive()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_iso_with_and_without_zone() {
        assert_eq!(parse("2026-10-18T12:00:00Z").unwrap().to_rfc3339(), "2026-10-18T12:00:00+00:00");
        assert_eq!(parse("2026-10-18T14:00:00+02:00").unwrap(), parse("2026-10-18T12:00:00Z").unwrap());
        assert!(parse("2027-10-13").is_some());
        assert!(parse("2027-10-13 09:30").is_some());
        assert!(parse("morgen").is_none());
    }

    #[test]
    fn formats_in_dutch() {
        let d = parse("2026-10-14T08:31:00").unwrap();
        assert_eq!(day(d), "woensdag 14 oktober 2026");
        assert_eq!(long(d), "woensdag 14 oktober 2026 08:31");
        assert_eq!(short(d), "wo 14 okt 08:31");
        assert_eq!(time(d), "08:31");
    }

    #[test]
    fn relative() {
        let now = parse("2026-10-14T12:00:00").unwrap();
        assert_eq!(ago_from(now - chrono::Duration::seconds(10), now), "zojuist");
        assert_eq!(ago_from(now - chrono::Duration::minutes(5), now), "5 min geleden");
        assert_eq!(ago_from(parse("2026-10-14T09:10:00").unwrap(), now), "vandaag om 09:10");
        assert_eq!(ago_from(parse("2026-10-13T09:10:00").unwrap(), now), "gisteren om 09:10");
    }
}
