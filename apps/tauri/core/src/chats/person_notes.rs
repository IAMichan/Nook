//! What you keep about a person yourself, by their chat's key in the inbox (the Mac's `ChatPersonNotes`): a note and a
//! birthday (month and day, no year). Today shows "It's Anna's birthday today" from it. Kept in `person-notes.json`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use chrono::{Datelike, NaiveDate};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PersonNote {
    pub note: String,
    /// "MM-DD".
    pub birthday: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PersonNotes {
    pub entries: BTreeMap<String, PersonNote>,
}

/// A birthday as kept: "MM-DD" from "03-14", "3-14" or "--03-14"; none for anything that is not a day of the year.
pub fn month_day(text: &str) -> Option<String> {
    let t = text.trim().trim_start_matches('-');
    let (m, d) = t.split_once('-')?;
    let (m, d) = (m.trim().parse::<u32>().ok()?, d.trim().parse::<u32>().ok()?);
    // 2024 has a 29 February, so every real day of the year passes.
    NaiveDate::from_ymd_opt(2024, m, d)?;
    Some(format!("{m:02}-{d:02}"))
}

/// Whether a birthday falls on `date`; a 29 February is kept on the 28th in other years.
pub fn falls_on(birthday: &str, date: NaiveDate) -> bool {
    let Some(day) = month_day(birthday) else { return false };
    let today = format!("{:02}-{:02}", date.month(), date.day());
    if day == today {
        return true;
    }
    day == "02-29" && today == "02-28" && NaiveDate::from_ymd_opt(date.year(), 2, 29).is_none()
}

impl PersonNotes {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("person-notes.json")
    }

    pub fn load() -> Self {
        std::fs::read_to_string(Self::file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        std::fs::write(Self::file(), serde_json::to_string_pretty(self).unwrap_or_default())
    }

    pub fn get(&self, key: &str) -> PersonNote {
        self.entries.get(key).cloned().unwrap_or_default()
    }

    /// Sets the note and birthday; an empty entry is forgotten.
    pub fn set(&mut self, key: &str, note: &str, birthday: Option<&str>) {
        let entry = PersonNote { note: note.trim().to_string(), birthday: birthday.and_then(month_day) };
        if entry.note.is_empty() && entry.birthday.is_none() {
            self.entries.remove(key);
        } else {
            self.entries.insert(key.to_string(), entry);
        }
    }

    /// The people whose birthday falls on `date`, by key.
    pub fn birthdays_on(&self, date: NaiveDate) -> Vec<String> {
        self.entries.iter().filter(|(_, e)| e.birthday.as_deref().is_some_and(|b| falls_on(b, date))).map(|(k, _)| k.clone()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_a_birthday_and_finds_it_on_the_day() {
        let mut notes = PersonNotes::default();
        notes.set("telegram#anna", "", Some("3-14"));
        notes.set("whatsapp#leap", "Born on a leap day", Some("02-29"));
        notes.set("x", "", Some("13-40"));
        assert_eq!(notes.get("telegram#anna").birthday.as_deref(), Some("03-14"));
        assert!(!notes.entries.contains_key("x"));
        assert_eq!(notes.birthdays_on(NaiveDate::from_ymd_opt(2026, 3, 14).unwrap()), vec!["telegram#anna"]);
        assert_eq!(notes.birthdays_on(NaiveDate::from_ymd_opt(2027, 2, 28).unwrap()), vec!["whatsapp#leap"]);
        assert!(notes.birthdays_on(NaiveDate::from_ymd_opt(2028, 2, 28).unwrap()).is_empty());
        notes.set("telegram#anna", "", None);
        assert!(!notes.entries.contains_key("telegram#anna"));
    }
}
