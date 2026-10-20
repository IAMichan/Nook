//! What Nook does while you share your screen or sit in a meeting (`QuietPolicy` on the Mac). The platform layer reads
//! the signals (the windows on screen, which apps have the microphone open); deciding what they mean lives here, so it
//! is tested without a desktop.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// What Nook does while you share your screen or sit in a meeting (Settings › Voice and sound › Meetings and screen
/// sharing).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuietBehavior {
    /// Nothing changes.
    Normal,
    /// No pop-ups of his own: no suggestions, agent cards or sounds. What you open yourself still works.
    Quiet,
    /// Quiet, and Nook is left out of what you share: you still see him, the people watching do not.
    HideFromShare,
    /// Quiet, and Nook is gone for you too until it is over: the bar, the main window and the small windows. A shortcut
    /// or the tray still opens it.
    Hide,
}

impl QuietBehavior {
    pub const ALL: [QuietBehavior; 4] = [Self::Normal, Self::Quiet, Self::HideFromShare, Self::Hide];
    /// The choices for a meeting: leaving Nook out of a share only means something while you share.
    pub const MEETING_CHOICES: [QuietBehavior; 3] = [Self::Normal, Self::Quiet, Self::Hide];

    /// The choice as it applies to a meeting: "hide from viewers" is a choice for sharing only and counts as quiet.
    pub fn for_meeting(self) -> Self {
        if self == Self::HideFromShare {
            Self::Quiet
        } else {
            self
        }
    }
}

/// What is going on right now.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuietSituation {
    pub sharing: bool,
    pub meeting: bool,
}

/// How Nook behaves right now.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuietState {
    /// No pop-ups or sounds Nook starts by himself.
    pub silent: bool,
    /// Left out of screen sharing and recordings.
    pub excluded_from_capture: bool,
    /// Nook's windows are put away until it is over.
    pub hidden: bool,
    /// Why, for the line in Settings.
    pub situation: QuietSituation,
}

impl QuietState {
    /// The line in Settings that says what Nook notices right now.
    pub fn status_text(&self) -> &'static str {
        match (self.situation.sharing, self.situation.meeting) {
            (true, true) => "In een meeting en je deelt je scherm",
            (true, false) => "Je deelt je scherm",
            (false, true) => "In een meeting",
            (false, false) => "Geen meeting, je deelt je scherm niet",
        }
    }
}

/// The state for what is going on and what you chose; sharing and a meeting at once take the strongest of both.
pub fn state(situation: QuietSituation, sharing: QuietBehavior, meeting: QuietBehavior) -> QuietState {
    let mut behaviors = vec![];
    if situation.sharing {
        behaviors.push(sharing);
    }
    if situation.meeting {
        behaviors.push(meeting.for_meeting());
    }
    let mut state = QuietState { situation, ..Default::default() };
    for behavior in behaviors {
        match behavior {
            QuietBehavior::Normal => {}
            QuietBehavior::Quiet => state.silent = true,
            QuietBehavior::HideFromShare => {
                state.silent = true;
                state.excluded_from_capture = true;
            }
            QuietBehavior::Hide => {
                state.silent = true;
                state.excluded_from_capture = true;
                state.hidden = true;
            }
        }
    }
    state
}

// Screen sharing

/// A top-level window on screen, as the platform lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    /// The program: the exe name on Windows ("Zoom", "ms-teams"), WM_CLASS on Linux, plus a display name if known.
    pub owner: String,
    /// The window title.
    pub name: String,
    /// Height in logical pixels.
    pub height: f64,
}

impl Window {
    pub fn new(owner: &str, name: &str, height: f64) -> Self {
        Self { owner: owner.into(), name: name.into(), height }
    }
}

/// Call apps whose sharing bar says "share" in its window title (Zoom's "zoom share toolbar window", Teams' "Sharing
/// control bar", Webex's sharing bar).
pub const SHARING_CALL_APPS: [&str; 11] =
    ["zoom", "teams", "webex", "ciscocollabhost", "atmgr", "slack", "discord", "skype", "whereby", "around", "gather"];
/// Words for "sharing" in such a bar, in the languages these apps are used in.
pub const SHARING_WORDS: [&str; 11] =
    ["share", "sharing", "deelt", "delen", "gedeeld", "teilt", "freigabe", "freigeben", "partage", "compartiendo", "compartir"];
/// Browsers: while a site shares your screen they show a small bar ("meet.google.com is sharing your screen.").
pub const BROWSERS: [&str; 12] =
    ["chrome", "chromium", "edge", "brave", "arc", "vivaldi", "opera", "firefox", "librewolf", "floorp", "zen", "epiphany"];
/// The sentence in that bar, in the browser's language.
pub const BROWSER_SHARING_PHRASES: [&str; 14] = [
    "is sharing",
    "sharing your screen",
    "sharing a window",
    "sharing this tab",
    "deelt je scherm",
    "deelt een venster",
    "deelt dit tabblad",
    "deelt uw scherm",
    "bildschirm frei",
    "fenster frei",
    "teilt",
    "partage",
    "compartiendo",
    "comparte",
];
/// The system's own capture tools: the overlay of the Windows Snipping Tool (screenshots and screen recordings).
pub const SYSTEM_CAPTURE: [&str; 1] = ["screenclippinghost"];

/// A sharing bar is small (in logical pixels); a full browser window titled "File sharing tips" is not one.
pub const BAR_MAX_HEIGHT: f64 = 160.0;

/// Does any of these windows say your screen is being shared or recorded? With `count_system_capture` off, the
/// system's own screenshot tool does not count, so Nook shows up in your screenshots.
pub fn is_sharing(windows: &[Window], count_system_capture: bool) -> bool {
    windows.iter().any(|w| is_sharing_window(w, count_system_capture))
}

pub fn is_sharing_window(window: &Window, count_system_capture: bool) -> bool {
    let owner = window.owner.to_lowercase();
    let name = window.name.to_lowercase();
    if SYSTEM_CAPTURE.iter().any(|tool| owner.contains(tool)) {
        return count_system_capture;
    }
    // A sharing bar is small: a Slack window on the channel "#file-sharing" is not one.
    if name.trim().is_empty() || window.height > BAR_MAX_HEIGHT {
        return false;
    }
    if BROWSERS.iter().any(|b| owner.contains(b)) {
        return BROWSER_SHARING_PHRASES.iter().any(|p| name.contains(p));
    }
    if SHARING_CALL_APPS.iter().any(|a| owner.contains(a)) {
        return SHARING_WORDS.iter().any(|w| name.contains(w));
    }
    false
}

// Meetings

/// Apps you hold calls in, by program name (the exe on Windows, the binary on Linux, a package name for Store apps);
/// while one of them has the microphone open, you are in a call.
pub const CALL_APPS: [&str; 16] = [
    "zoom",
    "ms-teams",
    "msteams",
    "teams",
    "microsoft.teams",
    "webex",
    "ciscocollabhost",
    "atmgr",
    "discord",
    "slack",
    "skype",
    "whatsapp",
    "telegram",
    "signal",
    "gather",
    "around",
];

fn program(name: &str) -> String {
    let lower = name.trim().to_lowercase();
    let file = lower.rsplit(['\\', '/']).next().unwrap_or(&lower).to_string();
    file.strip_suffix(".exe").map(str::to_string).unwrap_or(file)
}

/// A call app; helpers and Store packages share its name as a prefix ("ms-teams", "MSTeams_8wekyb3d8bbwe").
pub fn is_call_app(name: &str) -> bool {
    let name = program(name);
    CALL_APPS.iter().any(|app| name.starts_with(app))
}

/// A browser by program name ("chrome", "msedge", "google-chrome-stable", "firefox").
pub fn is_browser(name: &str) -> bool {
    let name = program(name);
    let bare = name.trim_start_matches("google-").trim_start_matches("ms");
    BROWSERS.iter().any(|b| bare.starts_with(b))
}

/// Browser window titles that are a meeting on the web.
pub const MEETING_SITES: [&str; 11] = [
    "google meet",
    "meet.google.com",
    "meet - ",
    "microsoft teams",
    "teams.microsoft.com",
    "zoom meeting",
    "app.zoom.us",
    "whereby",
    "jitsi",
    "around.co",
    "webex",
];

pub fn is_meeting_site(window_name: &str) -> bool {
    let name = window_name.to_lowercase();
    MEETING_SITES.iter().any(|s| name.contains(s))
}

/// An event in your calendar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Event {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

/// The signals of a meeting.
#[derive(Debug, Clone, PartialEq)]
pub struct MeetingSignals {
    pub now: DateTime<Utc>,
    /// Calendar events around now; only counted when `use_calendar` is on. All-day events are left out by the caller.
    pub events: Vec<Event>,
    pub use_calendar: bool,
    /// Programs that have the microphone open right now (Nook itself left out).
    pub microphone_apps: Vec<String>,
    /// Titles of the windows on screen: a meeting site in a browser ("Meet – Weekly sync").
    pub window_names: Vec<String>,
    /// Nook's Notetaker is recording a call.
    pub recording: bool,
}

impl MeetingSignals {
    pub fn new(now: DateTime<Utc>) -> Self {
        Self { now, events: vec![], use_calendar: true, microphone_apps: vec![], window_names: vec![], recording: false }
    }
}

/// In a meeting: the Notetaker recording a call, a call app with the microphone open (being in front is not enough:
/// Teams and Slack are also where you chat), a browser with the microphone open while a meeting site is on screen, or an
/// event going on in your calendar. Events of twelve hours or more are not meetings.
pub fn is_meeting(signals: &MeetingSignals) -> bool {
    if signals.recording {
        return true;
    }
    if signals.microphone_apps.iter().any(|a| is_call_app(a)) {
        return true;
    }
    if signals.microphone_apps.iter().any(|a| is_browser(a)) && signals.window_names.iter().any(|n| is_meeting_site(n)) {
        return true;
    }
    if !signals.use_calendar {
        return false;
    }
    signals.events.iter().any(|e| e.start <= signals.now && e.end > signals.now && (e.end - e.start).num_seconds() < 12 * 3600)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    // Choices

    #[test]
    fn nothing_going_on_changes_nothing() {
        let s = state(QuietSituation::default(), QuietBehavior::Hide, QuietBehavior::Hide);
        assert_eq!(s, QuietState::default());
    }

    #[test]
    fn each_choice_goes_further_than_the_last_one() {
        let sharing = QuietSituation { sharing: true, meeting: false };
        assert!(!state(sharing, QuietBehavior::Normal, QuietBehavior::Hide).silent);

        let quiet = state(sharing, QuietBehavior::Quiet, QuietBehavior::Normal);
        assert!(quiet.silent && !quiet.excluded_from_capture && !quiet.hidden);

        let unseen = state(sharing, QuietBehavior::HideFromShare, QuietBehavior::Normal);
        assert!(unseen.silent && unseen.excluded_from_capture && !unseen.hidden);

        let hidden = state(sharing, QuietBehavior::Hide, QuietBehavior::Normal);
        assert!(hidden.silent && hidden.excluded_from_capture && hidden.hidden);
    }

    #[test]
    fn sharing_during_a_meeting_takes_the_stronger_choice() {
        let both = QuietSituation { sharing: true, meeting: true };
        let s = state(both, QuietBehavior::HideFromShare, QuietBehavior::Hide);
        assert!(s.hidden);
        assert_eq!(s.situation, both);
        // Only the meeting choice applies when you are not sharing.
        let meeting = state(QuietSituation { sharing: false, meeting: true }, QuietBehavior::Hide, QuietBehavior::Quiet);
        assert!(meeting.silent && !meeting.hidden);
    }

    #[test]
    fn a_meeting_cannot_only_leave_the_share() {
        assert!(!QuietBehavior::MEETING_CHOICES.contains(&QuietBehavior::HideFromShare));
        let s = state(QuietSituation { sharing: false, meeting: true }, QuietBehavior::Normal, QuietBehavior::HideFromShare);
        assert!(s.silent && !s.excluded_from_capture);
        assert_eq!(serde_json::to_string(&QuietBehavior::HideFromShare).unwrap(), "\"hideFromShare\"");
    }

    #[test]
    fn the_status_line_names_what_is_going_on() {
        let s = state(QuietSituation { sharing: true, meeting: false }, QuietBehavior::Normal, QuietBehavior::Normal);
        assert_eq!(s.status_text(), "Je deelt je scherm");
        assert_eq!(QuietState::default().status_text(), "Geen meeting, je deelt je scherm niet");
    }

    // Screen sharing

    #[test]
    fn sharing_bars_of_call_apps_and_browsers_count() {
        assert!(is_sharing(&[Window::new("Zoom", "zoom share toolbar window", 52.0)], true));
        assert!(is_sharing(&[Window::new("ms-teams Microsoft Teams", "Sharing control bar", 60.0)], true));
        assert!(is_sharing(&[Window::new("chrome Google Chrome", "meet.google.com is sharing your screen.", 48.0)], true));
        assert!(is_sharing(&[Window::new("msedge", "meet.google.com deelt je scherm.", 48.0)], true));
        assert!(is_sharing(&[Window::new("brave", "meet.google.com gibt Ihren Bildschirm frei.", 48.0)], true));
    }

    #[test]
    fn the_snipping_overlay_counts_even_without_a_title() {
        assert!(is_sharing(&[Window::new("ScreenClippingHost", "", 1080.0)], true));
    }

    #[test]
    fn the_screenshot_tool_can_be_left_out() {
        let tool = Window::new("ScreenClippingHost", "", 1080.0);
        assert!(!is_sharing(std::slice::from_ref(&tool), false));
        // A real share still counts.
        assert!(is_sharing(&[tool, Window::new("ms-teams", "Sharing control bar", 60.0)], false));
    }

    #[test]
    fn ordinary_windows_do_not_count() {
        assert!(!is_sharing(&[Window::new("firefox", "File sharing is sharing done right", 900.0)], true));
        assert!(!is_sharing(&[Window::new("slack", "file-sharing (Channel) - Acme - Slack", 820.0)], true));
        assert!(!is_sharing(&[Window::new("Zoom", "", 40.0)], true));
        assert!(!is_sharing(&[Window::new("explorer", "Shared", 40.0)], true));
        assert!(!is_sharing(&[], true));
    }

    // Meetings

    #[test]
    fn a_call_app_with_the_microphone_is_a_meeting() {
        let mut signals = MeetingSignals::new(now());
        signals.use_calendar = false;
        assert!(!is_meeting(&signals));
        signals.microphone_apps = vec!["Zoom.exe".into()];
        assert!(is_meeting(&signals));
        // Store packages and helpers carry the app's name.
        signals.microphone_apps = vec!["MSTeams_8wekyb3d8bbwe".into()];
        assert!(is_meeting(&signals));
        signals.microphone_apps = vec![r"C:\Users\me\AppData\Local\Discord\app-1.0\Discord.exe".into()];
        assert!(is_meeting(&signals));
    }

    #[test]
    fn dictating_in_another_app_is_no_meeting() {
        let mut signals = MeetingSignals::new(now());
        signals.microphone_apps = vec!["audacity".into(), "SoundRecorder".into()];
        assert!(!is_meeting(&signals));
    }

    #[test]
    fn a_browser_counts_only_with_a_meeting_site_on_screen() {
        assert!(is_browser("msedge.exe") && is_browser("google-chrome-stable") && is_browser("firefox"));
        assert!(!is_browser("SearchHost") && !is_browser("Zoom"));
        let mut signals = MeetingSignals::new(now());
        signals.microphone_apps = vec!["chrome.exe".into()];
        signals.window_names = vec!["Inbox - Gmail".into()];
        assert!(!is_meeting(&signals));
        signals.window_names = vec!["Meet - abc-defg-hij".into()];
        assert!(is_meeting(&signals));
        // A meeting site without the microphone open is just a tab.
        signals.microphone_apps = vec![];
        assert!(!is_meeting(&signals));
    }

    #[test]
    fn recording_a_call_is_a_meeting() {
        let mut signals = MeetingSignals::new(now());
        signals.recording = true;
        assert!(is_meeting(&signals));
    }

    #[test]
    fn an_event_going_on_counts_only_when_you_want_it_to() {
        let mut signals = MeetingSignals::new(now());
        signals.events = vec![Event { start: now() - Duration::minutes(10), end: now() + Duration::minutes(20) }];
        assert!(is_meeting(&signals));
        signals.use_calendar = false;
        assert!(!is_meeting(&signals));
    }

    #[test]
    fn long_and_later_events_are_no_meeting() {
        let mut signals = MeetingSignals::new(now());
        signals.events = vec![
            Event { start: now() - Duration::hours(10), end: now() + Duration::hours(14) },
            Event { start: now() + Duration::minutes(10), end: now() + Duration::minutes(30) },
            Event { start: now() - Duration::minutes(30), end: now() },
        ];
        assert!(!is_meeting(&signals));
    }
}
