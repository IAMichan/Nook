//! Picks concrete times for a meeting or a block of focus work out of the busy intervals of every calendar, so the
//! brain proposes "Tuesday 10:00–11:00" instead of doing time arithmetic on a list of gaps (small models get that
//! wrong). Pure logic: `find_time` (`connectors::hub`) gathers the busy times, this decides.

use std::ops::Range;

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc, Weekday};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Busy {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

/// Which part of the day the user prefers. `Any` takes the earliest time that fits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Preference {
    #[default]
    Any,
    Morning,
    Afternoon,
    Evening,
}

impl Preference {
    pub fn from_text(text: Option<&str>) -> Self {
        match text.unwrap_or("").trim().to_lowercase().as_str() {
            "morning" => Self::Morning,
            "afternoon" => Self::Afternoon,
            "evening" => Self::Evening,
            _ => Self::Any,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Any => "any",
            Self::Morning => "morning",
            Self::Afternoon => "afternoon",
            Self::Evening => "evening",
        }
    }

    /// The hours this preference covers, start inclusive and end exclusive.
    pub fn hours(self) -> Option<Range<u32>> {
        match self {
            Self::Any => None,
            Self::Morning => Some(0..12),
            Self::Afternoon => Some(12..17),
            Self::Evening => Some(17..24),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    pub duration: Duration,
    /// How many options to propose.
    pub count: usize,
    /// The hours a slot may fall in each day, in the user's time zone ("09:00" to "18:00" as minutes after midnight).
    pub day_start: i32,
    pub day_end: i32,
    /// Free time kept before and after every busy event (travel, a breather).
    pub buffer: Duration,
    pub weekends: bool,
    pub preference: Preference,
    /// Starts fall on this grid (a quarter of an hour), so a proposal reads 10:15, never 10:07.
    pub step: Duration,
}

impl Request {
    pub fn new(from: DateTime<Utc>, to: DateTime<Utc>, duration: Duration) -> Self {
        Self {
            from,
            to,
            duration,
            count: 3,
            day_start: 9 * 60,
            day_end: 18 * 60,
            buffer: Duration::zero(),
            weekends: false,
            preference: Preference::Any,
            step: Duration::minutes(15),
        }
    }
}

/// At most this many days are searched, so a vague "some time" stays quick and the answer stays short.
pub const MAX_DAYS: i64 = 31;

/// Up to `count` slots in the local timezone, spread over different days first (one per day, the preferred part of
/// the day when it fits), then more on the same days. Nothing starts before `now`. Sorted by start.
pub fn find(request: &Request, busy: &[Busy], now: DateTime<Utc>) -> Vec<Slot> {
    find_in(request, busy, now, &Local)
}

/// Same as [`find`], in an explicit timezone (for DST and deterministic tests).
pub fn find_in<Tz: TimeZone>(request: &Request, busy: &[Busy], now: DateTime<Utc>, zone: &Tz) -> Vec<Slot> {
    if request.duration <= Duration::zero() || request.to <= request.from || request.day_end <= request.day_start {
        return Vec::new();
    }
    let count = request.count.clamp(1, 10);
    let buffer = request.buffer.max(Duration::zero());
    let expanded: Vec<Busy> = busy.iter().map(|b| Busy { start: b.start - buffer, end: b.end.max(b.start) + buffer }).collect();
    let blocked = merge(&expanded);

    let mut per_day: Vec<Vec<Slot>> = Vec::new();
    let mut day_date = request.from.with_timezone(zone).date_naive();
    let mut day = resolve_local(day_date.and_hms_opt(0, 0, 0).unwrap_or_default(), zone).unwrap_or(request.from);
    let mut days = 0;

    while day < request.to && days < MAX_DAYS {
        days += 1;
        let Some(next_date) = day_date.succ_opt() else { break };
        let Some(next) = next_date.and_hms_opt(0, 0, 0).and_then(|n| resolve_local(n, zone)) else { break };

        let is_weekend = matches!(day_date.weekday(), Weekday::Sat | Weekday::Sun);
        if request.weekends || !is_weekend {
            // By the clock, not by seconds since midnight: a day with a daylight saving switch keeps 09:00 at 09:00.
            let open = clock(request.day_start, day_date, day, next, zone);
            let close = clock(request.day_end, day_date, day, next, zone);
            let start = open.max(request.from).max(now);
            let end = close.min(request.to);
            if end > start {
                let gaps = free(&blocked, start, end);
                let starts = candidates(&gaps, request.duration, request.step, day);
                if !starts.is_empty() {
                    per_day.push(starts.into_iter().map(|s| Slot { start: s, end: s + request.duration }).collect());
                }
            }
        }

        day_date = next_date;
        day = next;
    }

    let mut chosen: Vec<Slot> = Vec::new();
    // First pass: one per day, the preferred part of the day when that day has it.
    for options in &per_day {
        if chosen.len() >= count {
            break;
        }
        if let Some(pick) = preferred(options, request.preference, zone) {
            chosen.push(pick);
        }
    }
    // Second pass: more on the same days, never overlapping what was chosen, still preferred times first.
    if chosen.len() < count {
        let rest: Vec<Slot> =
            per_day.iter().flatten().copied().filter(|slot| !chosen.iter().any(|c| c.start < slot.end && slot.start < c.end)).collect();
        for slot in ordered(&rest, request.preference, zone) {
            if chosen.len() >= count {
                break;
            }
            if !chosen.iter().any(|c| c.start < slot.end && slot.start < c.end) {
                chosen.push(slot);
            }
        }
    }
    chosen.sort_by_key(|s| s.start);
    chosen
}

fn resolve_local<Tz: TimeZone>(naive: NaiveDateTime, zone: &Tz) -> Option<DateTime<Utc>> {
    zone.from_local_datetime(&naive)
        .earliest()
        .or_else(|| zone.from_local_datetime(&(naive + Duration::hours(1))).earliest())
        .map(|d| d.with_timezone(&Utc))
}

/// `minutes` after midnight on `day_date` by the clock; midnight at the end of the day is `next`.
fn clock<Tz: TimeZone>(minutes: i32, day_date: NaiveDate, day: DateTime<Utc>, next: DateTime<Utc>, zone: &Tz) -> DateTime<Utc> {
    if minutes >= 24 * 60 {
        return next;
    }
    let minutes = minutes.max(0);
    let hour = (minutes / 60) as u32;
    let minute = (minutes % 60) as u32;
    day_date.and_hms_opt(hour, minute, 0).and_then(|n| resolve_local(n, zone)).unwrap_or_else(|| day + Duration::minutes(minutes as i64))
}

/// Overlapping or touching intervals joined, sorted by start.
pub fn merge(busy: &[Busy]) -> Vec<Busy> {
    let mut items: Vec<Busy> = busy.iter().copied().filter(|b| b.end > b.start).collect();
    items.sort_by_key(|b| b.start);
    let mut merged: Vec<Busy> = Vec::new();
    for item in items {
        if let Some(last) = merged.last_mut() {
            if item.start <= last.end {
                last.end = last.end.max(item.end);
                continue;
            }
        }
        merged.push(item);
    }
    merged
}

/// The free gaps between `from` and `to`.
pub fn free(blocked: &[Busy], from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<Slot> {
    let mut cursor = from;
    let mut gaps = Vec::new();
    for item in blocked {
        if item.end <= cursor {
            continue;
        }
        if item.start >= to {
            break;
        }
        if item.start > cursor {
            gaps.push(Slot { start: cursor, end: item.start });
        }
        cursor = cursor.max(item.end);
    }
    if to > cursor {
        gaps.push(Slot { start: cursor, end: to });
    }
    gaps
}

/// Every start on the grid (counted from midnight) where the whole duration fits in a gap.
fn candidates(gaps: &[Slot], duration: Duration, step: Duration, day: DateTime<Utc>) -> Vec<DateTime<Utc>> {
    let grid_secs = step.num_seconds().max(60);
    let grid = Duration::seconds(grid_secs);
    let grid_ns = grid_secs as i128 * 1_000_000_000;
    let mut starts = Vec::new();
    for gap in gaps {
        let delta = gap.start - day;
        let offset_ns = delta.num_nanoseconds().map(i128::from).unwrap_or_else(|| delta.num_seconds() as i128 * 1_000_000_000);
        let k = offset_ns.div_euclid(grid_ns) + i128::from(offset_ns.rem_euclid(grid_ns) != 0);
        let mut start = day + Duration::seconds((k as i64) * grid_secs);
        while start + duration <= gap.end {
            starts.push(start);
            start += grid;
        }
    }
    starts
}

fn in_preference<Tz: TimeZone>(slot: &Slot, preference: Preference, zone: &Tz) -> bool {
    let Some(hours) = preference.hours() else { return true };
    hours.contains(&slot.start.with_timezone(zone).hour())
}

fn preferred<Tz: TimeZone>(options: &[Slot], preference: Preference, zone: &Tz) -> Option<Slot> {
    options.iter().find(|s| in_preference(s, preference, zone)).or_else(|| options.first()).copied()
}

fn ordered<Tz: TimeZone>(options: &[Slot], preference: Preference, zone: &Tz) -> Vec<Slot> {
    let mut sorted = options.to_vec();
    sorted.sort_by_key(|s| s.start);
    let (pref, other): (Vec<Slot>, Vec<Slot>) = sorted.into_iter().partition(|s| in_preference(s, preference, zone));
    pref.into_iter().chain(other).collect()
}

/// "09:30" or "9" as minutes after midnight; `None` for anything else.
pub fn minutes(text: Option<&str>) -> Option<i32> {
    let trimmed = text?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut parts = trimmed.split(':');
    let hour: i32 = parts.next()?.parse().ok()?;
    if !(0..=24).contains(&hour) {
        return None;
    }
    let minute: i32 = match parts.next() {
        Some(m) => {
            let prefix: String = m.chars().take(2).collect();
            prefix.parse().unwrap_or(0)
        }
        None => 0,
    };
    if !(0..60).contains(&minute) {
        return None;
    }
    Some((hour * 60 + minute).min(24 * 60))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono_tz::Europe::Amsterdam;

    /// Monday 2026-11-16 at the given time, Amsterdam.
    fn at(day: u32, hour: u32, minute: u32) -> DateTime<Utc> {
        Amsterdam.with_ymd_and_hms(2026, 11, day, hour, minute, 0).unwrap().with_timezone(&Utc)
    }

    fn busy(day: u32, from: u32, to: u32) -> Busy {
        Busy { start: at(day, from, 0), end: at(day, to, 0) }
    }

    #[test]
    fn one_option_per_day_first() {
        let request = Request::new(at(16, 0, 0), at(19, 0, 0), Duration::hours(1));
        let slots = find_in(&request, &[busy(16, 9, 11)], at(16, 8, 0), &Amsterdam);
        let starts: Vec<_> = slots.iter().map(|s| s.start).collect();
        assert_eq!(starts, [at(16, 11, 0), at(17, 9, 0), at(18, 9, 0)]);
        assert_eq!(slots[0].end, at(16, 12, 0));
    }

    #[test]
    fn nothing_starts_before_now_and_starts_sit_on_the_quarter_hour() {
        let mut request = Request::new(at(16, 0, 0), at(17, 0, 0), Duration::minutes(30));
        request.count = 1;
        let slots = find_in(&request, &[], at(16, 13, 7), &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [at(16, 13, 15)]);

        // Sub-second `now` past a quarter hour still moves to the next quarter hour.
        let past = at(16, 13, 15) + Duration::milliseconds(100);
        let slots = find_in(&request, &[], past, &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [at(16, 13, 30)]);
    }

    #[test]
    fn buffer_keeps_time_around_other_appointments() {
        let mut request = Request::new(at(16, 0, 0), at(17, 0, 0), Duration::hours(1));
        request.count = 1;
        request.buffer = Duration::minutes(30);
        let slots = find_in(&request, &[busy(16, 9, 10)], at(16, 0, 0), &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [at(16, 10, 30)]);
    }

    #[test]
    fn skips_weekends_unless_asked() {
        // Saturday 21 and Sunday 22 November.
        let mut request = Request::new(at(21, 0, 0), at(23, 0, 0), Duration::hours(1));
        request.count = 2;
        assert!(find_in(&request, &[], at(16, 0, 0), &Amsterdam).is_empty());
        request.weekends = true;
        let slots = find_in(&request, &[], at(16, 0, 0), &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [at(21, 9, 0), at(22, 9, 0)]);
    }

    #[test]
    fn prefers_the_part_of_the_day_asked() {
        let mut request = Request::new(at(16, 0, 0), at(17, 0, 0), Duration::hours(1));
        request.count = 1;
        request.preference = Preference::Afternoon;
        let slots = find_in(&request, &[], at(16, 0, 0), &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [at(16, 12, 0)]);

        // A day without afternoon room still offers its morning.
        let full = find_in(&request, &[busy(16, 12, 18)], at(16, 0, 0), &Amsterdam);
        assert_eq!(full.iter().map(|s| s.start).collect::<Vec<_>>(), [at(16, 9, 0)]);
    }

    #[test]
    fn fills_up_the_same_day_without_overlap() {
        let mut request = Request::new(at(16, 0, 0), at(17, 0, 0), Duration::hours(1));
        request.count = 3;
        let slots = find_in(&request, &[busy(16, 10, 17)], at(16, 0, 0), &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [at(16, 9, 0), at(16, 17, 0)]);
    }

    #[test]
    fn overlapping_busy_times_merge() {
        let merged = merge(&[busy(16, 9, 11), busy(16, 10, 12), busy(16, 14, 15)]);
        assert_eq!(merged, [busy(16, 9, 12), busy(16, 14, 15)]);
    }

    #[test]
    fn reads_clock_times() {
        assert_eq!(minutes(Some("09:30")), Some(570));
        assert_eq!(minutes(Some("18")), Some(1080));
        assert_eq!(minutes(Some("late")), None);
        assert_eq!(Preference::from_text(Some("Morning")), Preference::Morning);
        assert_eq!(Preference::from_text(None), Preference::Any);
    }

    #[test]
    fn daylight_saving_switch_keeps_clock_hours() {
        // Sunday 2026-10-25 in Europe/Amsterdam clocks fall back at 03:00 -> 02:00 (25-hour day).
        let oct25 = |h: u32, m: u32| Amsterdam.with_ymd_and_hms(2026, 10, 25, h, m, 0).unwrap().with_timezone(&Utc);
        let oct26 = |h: u32, m: u32| Amsterdam.with_ymd_and_hms(2026, 10, 26, h, m, 0).unwrap().with_timezone(&Utc);
        let mut request = Request::new(oct25(0, 0), oct26(0, 0), Duration::hours(1));
        request.weekends = true;
        request.count = 1;
        let slots = find_in(&request, &[], oct25(0, 0), &Amsterdam);
        assert_eq!(slots.iter().map(|s| s.start).collect::<Vec<_>>(), [oct25(9, 0)]);
    }
}
