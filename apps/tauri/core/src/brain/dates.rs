//! Datums zoals Nook ze leest en schrijft: ISO 8601 van het brein, en Nederlandse weergave voor de gebruiker.

use chrono::{DateTime, Datelike, Duration, FixedOffset, Local, NaiveDate, NaiveDateTime, TimeZone, Timelike, Weekday};

/// Leest ISO 8601 met of zonder tijdzone. Zonder tijdzone geldt de tijdzone van deze computer.
pub fn parse(text: &str) -> Option<DateTime<FixedOffset>> {
    parse_in(text, &Local)
}

pub fn parse_in<Tz: TimeZone>(text: &str, zone: &Tz) -> Option<DateTime<FixedOffset>> {
    let trimmed = text.trim();
    if let Ok(date) = DateTime::parse_from_rfc3339(trimmed) {
        return Some(date);
    }
    for format in ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(trimmed, format) {
            return zone.from_local_datetime(&naive).earliest().map(|d| d.fixed_offset());
        }
    }
    let day = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d").ok()?;
    zone.from_local_datetime(&day.and_hms_opt(0, 0, 0)?).earliest().map(|d| d.fixed_offset())
}

/// ISO 8601 in de tijdzone van deze computer, zonder fracties.
pub fn iso(date: DateTime<FixedOffset>) -> String {
    date.with_timezone(&Local).to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

const WEEKDAYS: [&str; 7] = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"];
const WEEKDAYS_SHORT: [&str; 7] = ["ma", "di", "wo", "do", "vr", "za", "zo"];
const MONTHS: [&str; 12] =
    ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"];
const MONTHS_SHORT: [&str; 12] = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"];

fn weekday_index<D: Datelike>(date: &D) -> usize {
    date.weekday().num_days_from_monday() as usize
}

/// "vr 16 okt 14:00"
pub fn short<D: Datelike + Timelike>(date: &D) -> String {
    format!(
        "{} {} {} {:02}:{:02}",
        WEEKDAYS_SHORT[weekday_index(date)],
        date.day(),
        MONTHS_SHORT[date.month0() as usize],
        date.hour(),
        date.minute()
    )
}

/// "woensdag"
pub fn weekday<D: Datelike>(date: &D) -> &'static str {
    WEEKDAYS[weekday_index(date)]
}

/// "12 okt"
pub fn day_month<D: Datelike>(date: &D) -> String {
    format!("{} {}", date.day(), MONTHS_SHORT[date.month0() as usize])
}

/// "woensdag 14 oktober 2026"
pub fn day<D: Datelike>(date: &D) -> String {
    format!("{} {} {} {}", weekday(date), date.day(), MONTHS[date.month0() as usize], date.year())
}

/// "woensdag 14 oktober 2026 08:31"
pub fn long<D: Datelike + Timelike>(date: &D) -> String {
    format!("{} {:02}:{:02}", day(date), date.hour(), date.minute())
}

fn english_weekday(day: Weekday) -> &'static str {
    match day {
        Weekday::Mon => "Monday",
        Weekday::Tue => "Tuesday",
        Weekday::Wed => "Wednesday",
        Weekday::Thu => "Thursday",
        Weekday::Fri => "Friday",
        Weekday::Sat => "Saturday",
        Weekday::Sun => "Sunday",
    }
}

/// De komende dagen met hun datum, zodat een klein model "vrijdag om 3 uur" in ISO 8601 kan zetten zonder te rekenen.
pub fn date_sheet<Tz: TimeZone>(now: &DateTime<Tz>, days: usize) -> String
where
    Tz::Offset: std::fmt::Display,
{
    let zone = now.timezone();
    let today = now.date_naive();
    let offset_of = |date: NaiveDate| -> String {
        zone.from_local_datetime(&date.and_hms_opt(12, 0, 0).unwrap_or_default())
            .earliest()
            .map(|d| d.format("%:z").to_string())
            .unwrap_or_else(|| now.format("%:z").to_string())
    };
    let lines: Vec<String> = (0..days.max(1))
        .map(|offset| {
            let date = today + Duration::days(offset as i64);
            let text = format!("{} {}", english_weekday(date.weekday()), date.format("%Y-%m-%d"));
            match offset {
                0 => format!("today: {text}"),
                1 => format!("tomorrow: {text}"),
                _ => text,
            }
        })
        .collect();
    // De eerstvolgende vrijdag, of vandaag als het vrijdag is.
    let ahead = (Weekday::Fri.num_days_from_monday() as i64 - today.weekday().num_days_from_monday() as i64).rem_euclid(7);
    let friday = today + Duration::days(ahead);
    format!(
        "Dates (timezone offset {}, now {}): {}. Example: friday 3 pm = {}T15:00:00{}.",
        now.format("%:z"),
        now.format("%H:%M"),
        lines.join("; "),
        friday.format("%Y-%m-%d"),
        offset_of(friday)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_with_and_without_zone() {
        let zone = FixedOffset::east_opt(2 * 3600).unwrap();
        assert_eq!(parse_in("2026-10-16T15:00:00+02:00", &zone).unwrap().hour(), 15);
        assert_eq!(parse_in("2026-10-16T15:00:00.250Z", &zone).unwrap().hour(), 15);
        let local = parse_in("2026-10-16T09:30", &zone).unwrap();
        assert_eq!(local.to_rfc3339(), "2026-10-16T09:30:00+02:00");
        assert!(parse_in("2026-10-16", &zone).is_some());
        assert!(parse_in("volgende week", &zone).is_none());
    }

    #[test]
    fn dutch_formats() {
        let date = NaiveDate::from_ymd_opt(2026, 10, 14).unwrap().and_hms_opt(8, 31, 0).unwrap();
        assert_eq!(long(&date), "woensdag 14 oktober 2026 08:31");
        assert_eq!(short(&date), "wo 14 okt 08:31");
    }

    #[test]
    fn date_sheet_spells_out_the_coming_days() {
        let zone = FixedOffset::east_opt(2 * 3600).unwrap();
        let now = zone.with_ymd_and_hms(2026, 10, 15, 9, 30, 0).unwrap();
        let sheet = date_sheet(&now, 8);
        assert!(sheet.contains("today: Thursday 2026-10-15"), "{sheet}");
        assert!(sheet.contains("tomorrow: Friday 2026-10-16"), "{sheet}");
        assert!(sheet.contains("+02:00"));
        assert!(sheet.contains("now 09:30"));
        assert!(sheet.contains("2026-10-16T15:00:00+02:00"));
    }
}
