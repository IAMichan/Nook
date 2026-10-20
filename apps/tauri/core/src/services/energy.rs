//! How much of its optional background work Nook does (Settings › General › Energy; `EnergyPolicy` on the Mac). Work
//! you ask for (a question, dictation, a look at the screen) always runs at full speed; this is about what Nook does by
//! himself: reading the screen on a timer, thinking along, checking for meetings. The platform layer reads the signals;
//! the plan is decided here, pure, so it is tested on its own.

use serde::{Deserialize, Serialize};

/// Your choice in Settings › General › Energy.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnergyMode {
    /// Nook steps back on battery, when the computer is hot or busy, and when you are away.
    #[default]
    Automatic,
    /// Always light: the screen is read less often and suggestions come less often.
    Saver,
    /// Never slows down for battery or a busy computer; a hot computer still gets a break.
    Full,
}

/// What the computer tells Nook right now. Gathered by the platform layer; a test fills it in by hand.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnergySignals {
    /// The system's battery saver (Windows) or a low-power profile (Linux) is on.
    pub low_power_mode: bool,
    /// The processor is running hot.
    pub hot: bool,
    /// Every core has more than enough to do (a build, an export).
    pub busy: bool,
    /// Running on the battery.
    pub on_battery: bool,
    /// No keyboard or pointer input for a while.
    pub away: bool,
    /// The displays are asleep.
    pub display_asleep: bool,
}

impl EnergySignals {
    /// After this long without input (seconds) you count as away: nothing on screen is being looked at.
    pub const AWAY_AFTER: f64 = 300.0;
    /// The load per core above which the computer counts as busy.
    pub const BUSY_PER_CORE: f64 = 1.0;
}

/// Why Nook does less than usual right now, in the order the status line names them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnergyReason {
    DisplayAsleep,
    Hot,
    LowPowerMode,
    Busy,
    Away,
    Battery,
    Saver,
}

impl EnergyReason {
    pub const ALL: [EnergyReason; 7] =
        [Self::DisplayAsleep, Self::Hot, Self::LowPowerMode, Self::Busy, Self::Away, Self::Battery, Self::Saver];

    /// The reason in a few words, for the status line.
    pub fn text(self) -> &'static str {
        match self {
            Self::DisplayAsleep => "je scherm slaapt",
            Self::Hot => "je computer is warm",
            Self::LowPowerMode => "energiebesparing staat aan",
            Self::Busy => "je computer is druk bezig",
            Self::Away => "je bent even weg",
            Self::Battery => "je computer draait op de accu",
            Self::Saver => "je koos voor Zuinig",
        }
    }
}

/// The tempo of the background work.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnergyPace {
    /// Everything as usual.
    Full,
    /// The same work, less often.
    Light,
    /// Optional work waits; what remains runs slowly.
    Paused,
}

/// What the background work should do right now: the pace, why, and the knobs the workers read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnergyPlan {
    pub pace: EnergyPace,
    pub reasons: Vec<EnergyReason>,
}

impl Default for EnergyPlan {
    fn default() -> Self {
        Self::full_speed()
    }
}

impl EnergyPlan {
    pub fn full_speed() -> Self {
        Self { pace: EnergyPace::Full, reasons: vec![] }
    }

    /// Multiply a worker's usual interval by this: 1 at full speed, 2 when light, 6 when paused.
    pub fn slowdown(&self) -> f64 {
        match self.pace {
            EnergyPace::Full => 1.0,
            EnergyPace::Light => 2.0,
            EnergyPace::Paused => 6.0,
        }
    }

    /// The screen is read on a timer, so an answer about it is ready at once.
    pub fn reads_screen(&self) -> bool {
        self.pace != EnergyPace::Paused
    }

    /// Nook looks over your shoulder and offers help by himself.
    pub fn thinks_along(&self) -> bool {
        self.pace != EnergyPace::Paused
    }

    /// At least this long (seconds) between two looks while thinking along, on top of the usual gaps: a look is a
    /// model run.
    pub fn think_along_gap(&self) -> f64 {
        match self.pace {
            EnergyPace::Full => 0.0,
            EnergyPace::Light => 600.0,
            EnergyPace::Paused => f64::INFINITY,
        }
    }

    /// How many windows the screen reader's timer keeps text of. Taking it easy, only the frontmost few: the others are
    /// read again fresh the moment a question asks about them.
    pub fn screen_window_limit(&self) -> usize {
        if self.pace == EnergyPace::Full {
            10
        } else {
            4
        }
    }

    /// How old (seconds) a window that is not in front may get before the timer reads it again.
    pub fn background_window_max_age(&self) -> f64 {
        if self.pace == EnergyPace::Full {
            30.0
        } else {
            90.0
        }
    }

    /// The first reason, for a short status line; `None` at full speed.
    pub fn main_reason(&self) -> Option<EnergyReason> {
        self.reasons.first().copied()
    }

    /// The status line: "Volle snelheid", or what Nook holds back for and why.
    pub fn status_text(&self) -> String {
        match (self.main_reason(), self.pace) {
            (None, _) | (_, EnergyPace::Full) => "Volle snelheid".into(),
            (Some(reason), EnergyPace::Paused) => format!("Even gepauzeerd: {}", reason.text()),
            (Some(reason), EnergyPace::Light) => format!("Rustig aan: {}", reason.text()),
        }
    }
}

/// Decides the plan from the signals and your choice.
pub fn plan(signals: &EnergySignals, mode: EnergyMode) -> EnergyPlan {
    let mut paused = vec![];
    let mut light = vec![];

    // Nobody is looking at the screen: the optional work has nothing to add.
    if signals.display_asleep {
        paused.push(EnergyReason::DisplayAsleep);
    }
    // A hot computer gets a break whatever you chose; working on would only keep it hot.
    if signals.hot {
        paused.push(EnergyReason::Hot);
    }
    // Battery saver is you asking the system to save power: Nook follows, unless you told him to keep going.
    if signals.low_power_mode {
        if mode == EnergyMode::Full {
            light.push(EnergyReason::LowPowerMode);
        } else {
            paused.push(EnergyReason::LowPowerMode);
        }
    }
    // Every core is full: Nook never competes with what you are doing, unless you told him not to mind.
    if signals.busy && mode != EnergyMode::Full {
        paused.push(EnergyReason::Busy);
    }
    if signals.away {
        paused.push(EnergyReason::Away);
    }
    if signals.on_battery && mode != EnergyMode::Full {
        light.push(EnergyReason::Battery);
    }
    if mode == EnergyMode::Saver {
        light.push(EnergyReason::Saver);
    }

    if !paused.is_empty() {
        paused.extend(light);
        return EnergyPlan { pace: EnergyPace::Paused, reasons: paused };
    }
    if !light.is_empty() {
        return EnergyPlan { pace: EnergyPace::Light, reasons: light };
    }
    EnergyPlan::full_speed()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signals(f: impl FnOnce(&mut EnergySignals)) -> EnergySignals {
        let mut s = EnergySignals::default();
        f(&mut s);
        s
    }

    #[test]
    fn a_quiet_computer_on_the_charger_runs_at_full_speed() {
        let p = plan(&EnergySignals::default(), EnergyMode::Automatic);
        assert_eq!(p, EnergyPlan::full_speed());
        assert_eq!(p.slowdown(), 1.0);
        assert!(p.reads_screen() && p.thinks_along());
        assert_eq!(p.think_along_gap(), 0.0);
        assert_eq!(p.main_reason(), None);
        assert_eq!(p.status_text(), "Volle snelheid");
    }

    #[test]
    fn the_battery_makes_the_work_lighter_not_paused() {
        let p = plan(&signals(|s| s.on_battery = true), EnergyMode::Automatic);
        assert_eq!(p.pace, EnergyPace::Light);
        assert_eq!(p.reasons, vec![EnergyReason::Battery]);
        assert_eq!(p.slowdown(), 2.0);
        assert!(p.reads_screen(), "the screen is still read, less often");
        assert_eq!(p.think_along_gap(), 600.0);
        assert_eq!(p.status_text(), "Rustig aan: je computer draait op de accu");
    }

    #[test]
    fn a_hot_busy_or_saving_computer_pauses_the_optional_work() {
        for s in [signals(|s| s.low_power_mode = true), signals(|s| s.hot = true), signals(|s| s.busy = true)] {
            let p = plan(&s, EnergyMode::Automatic);
            assert_eq!(p.pace, EnergyPace::Paused, "{s:?}");
            assert!(!p.reads_screen() && !p.thinks_along());
            assert_eq!(p.slowdown(), 6.0);
            assert_eq!(p.think_along_gap(), f64::INFINITY);
        }
    }

    #[test]
    fn away_and_a_sleeping_display_pause_everything_optional() {
        assert_eq!(plan(&signals(|s| s.away = true), EnergyMode::Full).pace, EnergyPace::Paused);
        assert_eq!(plan(&signals(|s| s.display_asleep = true), EnergyMode::Full).pace, EnergyPace::Paused);
        assert_eq!(plan(&signals(|s| s.away = true), EnergyMode::Automatic).status_text(), "Even gepauzeerd: je bent even weg");
    }

    #[test]
    fn the_reasons_name_the_strongest_first() {
        let p = plan(
            &signals(|s| {
                s.hot = true;
                s.on_battery = true;
                s.display_asleep = true;
            }),
            EnergyMode::Automatic,
        );
        assert_eq!(p.reasons, vec![EnergyReason::DisplayAsleep, EnergyReason::Hot, EnergyReason::Battery]);
        assert_eq!(p.main_reason(), Some(EnergyReason::DisplayAsleep));
    }

    #[test]
    fn saver_is_always_at_least_light() {
        let p = plan(&EnergySignals::default(), EnergyMode::Saver);
        assert_eq!(p.pace, EnergyPace::Light);
        assert_eq!(p.reasons, vec![EnergyReason::Saver]);
        // On battery the battery comes first: it is the reason you would expect to see.
        assert_eq!(plan(&signals(|s| s.on_battery = true), EnergyMode::Saver).reasons, vec![EnergyReason::Battery, EnergyReason::Saver]);
        assert_eq!(plan(&signals(|s| s.busy = true), EnergyMode::Saver).pace, EnergyPace::Paused);
    }

    #[test]
    fn full_power_ignores_the_battery_and_a_busy_computer_but_not_heat() {
        assert_eq!(plan(&signals(|s| s.on_battery = true), EnergyMode::Full), EnergyPlan::full_speed());
        assert_eq!(plan(&signals(|s| s.busy = true), EnergyMode::Full), EnergyPlan::full_speed());
        assert_eq!(plan(&signals(|s| s.hot = true), EnergyMode::Full).pace, EnergyPace::Paused);
        // Battery saver is your own request to the system: full power still takes it easy for it.
        let low = plan(&signals(|s| s.low_power_mode = true), EnergyMode::Full);
        assert_eq!(low.pace, EnergyPace::Light);
        assert_eq!(low.reasons, vec![EnergyReason::LowPowerMode]);
    }

    #[test]
    fn taking_it_easy_also_spares_the_processor() {
        let full = plan(&EnergySignals::default(), EnergyMode::Automatic);
        assert_eq!(full.screen_window_limit(), 10);
        assert_eq!(full.background_window_max_age(), 30.0);
        let light = plan(&signals(|s| s.on_battery = true), EnergyMode::Automatic);
        assert_eq!(light.screen_window_limit(), 4);
        assert_eq!(light.background_window_max_age(), 90.0);
        // Paused keeps the same light knobs for the work that still runs.
        assert_eq!(plan(&signals(|s| s.hot = true), EnergyMode::Automatic).screen_window_limit(), 4);
    }

    #[test]
    fn every_reason_has_a_text_and_modes_serialize_like_the_mac() {
        let texts: std::collections::BTreeSet<&str> = EnergyReason::ALL.iter().map(|r| r.text()).collect();
        assert_eq!(texts.len(), EnergyReason::ALL.len());
        let modes: Vec<String> =
            [EnergyMode::Automatic, EnergyMode::Saver, EnergyMode::Full].iter().map(|m| serde_json::to_string(m).unwrap()).collect();
        assert_eq!(modes, ["\"automatic\"", "\"saver\"", "\"full\""]);
    }
}
