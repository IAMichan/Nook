//! Meetings, screen sharing and power on Linux: the windows on screen via X11 (a sharing bar of a call app or browser;
//! under Wayland without XWayland Nook cannot see them), which programs record from a microphone (PulseAudio or
//! PipeWire via `pactl`), the battery and power profile (`/sys`), the load average and the screen saver.

use std::path::Path;
use std::time::Duration;

use nook_core::platform::{PowerMonitor, QuietWatch};
use nook_core::services::energy::EnergySignals;
use nook_core::services::quiet::Window;

use super::x11::X11;
use crate::platform::process;

pub struct LinuxQuiet {
    x11: Option<X11>,
}

impl LinuxQuiet {
    pub fn new() -> Self {
        Self { x11: X11::connect() }
    }
}

impl QuietWatch for LinuxQuiet {
    fn available(&self) -> bool {
        self.x11.is_some()
    }

    fn windows(&self) -> Vec<Window> {
        let own = std::process::id();
        let Some(x11) = &self.x11 else { return vec![] };
        x11.all_windows()
            .into_iter()
            .filter(|w| w.pid != own)
            .map(|w| Window { owner: w.class, name: w.title, height: w.height as f64 })
            .collect()
    }

    fn microphone_apps(&self) -> Vec<String> {
        if !process::which("pactl") {
            return vec![];
        }
        let own = std::process::id();
        // JSON (pactl 16 and later) is not translated; the text form is the fallback for older versions.
        if let Some(found) = process::run_text("pactl", &["-f", "json", "list", "source-outputs"], Duration::from_secs(2))
            .ok()
            .and_then(|text| recording_programs_json(&text, own))
        {
            return found;
        }
        process::run_text("pactl", &["list", "source-outputs"], Duration::from_secs(2))
            .map(|text| recording_programs(&text, own))
            .unwrap_or_default()
    }
}

/// Like [`recording_programs`], from `pactl -f json`. `None` if the output is not JSON.
fn recording_programs_json(text: &str, own: u32) -> Option<Vec<String>> {
    let list: Vec<serde_json::Value> = serde_json::from_str(text).ok()?;
    Some(
        list.iter()
            .filter(|o| !o["corked"].as_bool().unwrap_or(false))
            .filter_map(|o| {
                let props = &o["properties"];
                let pid = props["application.process.id"].as_str().and_then(|p| p.parse::<u32>().ok());
                if pid == Some(own) {
                    return None;
                }
                props["application.process.binary"].as_str().or(props["application.name"].as_str()).map(str::to_string)
            })
            .collect(),
    )
}

/// The programs in `pactl list source-outputs` that record right now (not corked), Nook (`own`) left out.
fn recording_programs(text: &str, own: u32) -> Vec<String> {
    let mut found = vec![];
    for block in text.split("Source Output #").skip(1) {
        let value = |key: &str| {
            block.lines().find_map(|line| {
                let (k, v) = line.trim().split_once(" = ")?;
                (k == key).then(|| v.trim_matches('"').to_string())
            })
        };
        let corked = block.lines().any(|l| l.trim() == "Corked: yes");
        let pid = value("application.process.id").and_then(|p| p.parse::<u32>().ok());
        if corked || pid == Some(own) {
            continue;
        }
        if let Some(name) = value("application.process.binary").or_else(|| value("application.name")) {
            found.push(name);
        }
    }
    found
}

pub struct LinuxPower {
    x11: Option<X11>,
}

impl LinuxPower {
    pub fn new() -> Self {
        Self { x11: X11::connect() }
    }
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// A battery that is discharging: the computer runs on it.
fn on_battery(root: &Path) -> bool {
    std::fs::read_dir(root)
        .map(|dir| {
            dir.flatten().any(|entry| read(&entry.path().join("type")) == "Battery" && read(&entry.path().join("status")) == "Discharging")
        })
        .unwrap_or(false)
}

/// The one-minute load average per core is above one: every core has more than enough to do.
fn busy(loadavg: &str, cores: usize) -> bool {
    loadavg
        .split_whitespace()
        .next()
        .and_then(|l| l.parse::<f64>().ok())
        .is_some_and(|l| l / cores.max(1) as f64 > EnergySignals::BUSY_PER_CORE)
}

/// The processor's own temperature sensor reads 95 °C or more.
fn hot(root: &Path) -> bool {
    std::fs::read_dir(root)
        .map(|dir| {
            dir.flatten().any(|zone| {
                let kind = read(&zone.path().join("type"));
                ["x86_pkg_temp", "cpu-thermal", "cpu_thermal", "k10temp"].contains(&kind.as_str())
                    && read(&zone.path().join("temp")).parse::<i64>().is_ok_and(|milli| milli >= 95_000)
            })
        })
        .unwrap_or(false)
}

impl PowerMonitor for LinuxPower {
    fn signals(&self) -> EnergySignals {
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        EnergySignals {
            low_power_mode: read(Path::new("/sys/firmware/acpi/platform_profile")) == "low-power",
            hot: hot(Path::new("/sys/class/thermal")),
            busy: busy(&read(Path::new("/proc/loadavg")), cores),
            on_battery: on_battery(Path::new("/sys/class/power_supply")),
            away: false,
            display_asleep: self.x11.as_ref().is_some_and(|x| x.screen_saver_on()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_programs_that_record() {
        let text = "Source Output #12\n\tCorked: no\n\tProperties:\n\t\tapplication.name = \"ZOOM VoiceEngine\"\n\t\tapplication.process.id = \"4242\"\n\t\tapplication.process.binary = \"zoom\"\nSource Output #13\n\tCorked: yes\n\tProperties:\n\t\tapplication.process.binary = \"firefox\"\nSource Output #14\n\tCorked: no\n\tProperties:\n\t\tapplication.process.id = \"7\"\n\t\tapplication.process.binary = \"nook\"\n";
        assert_eq!(recording_programs(text, 7), vec!["zoom".to_string()]);
        let json = r#"[{"index":12,"corked":false,"properties":{"application.process.binary":"zoom","application.process.id":"4242"}},
            {"index":13,"corked":true,"properties":{"application.process.binary":"firefox"}},
            {"index":14,"corked":false,"properties":{"application.process.binary":"nook","application.process.id":"7"}}]"#;
        assert_eq!(recording_programs_json(json, 7), Some(vec!["zoom".to_string()]));
        assert_eq!(recording_programs_json("Source Output #1", 7), None);
    }

    #[test]
    fn load_and_battery() {
        assert!(busy("9.50 4.00 2.00 3/900 1234", 8));
        assert!(!busy("2.10 4.00 2.00 3/900 1234", 8));
        let dir = std::env::temp_dir().join(format!("nook-power-{}", std::process::id()));
        let bat = dir.join("BAT0");
        std::fs::create_dir_all(&bat).unwrap();
        std::fs::write(bat.join("type"), "Battery\n").unwrap();
        std::fs::write(bat.join("status"), "Charging\n").unwrap();
        assert!(!on_battery(&dir));
        std::fs::write(bat.join("status"), "Discharging\n").unwrap();
        assert!(on_battery(&dir));
        let _ = std::fs::remove_dir_all(dir);
    }
}
