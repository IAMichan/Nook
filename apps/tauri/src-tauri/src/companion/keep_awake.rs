//! Holding off sleep for the companion (`KeepAwake.swift` on the Mac); when to hold is decided by
//! `nook_core::companion::keep_awake`. Windows: `SetThreadExecutionState` on a thread of its own, held until released.
//! Linux: a `systemd-inhibit` child, ended when released. Elsewhere (a development build on a Mac) nothing is held.

use nook_core::companion::keep_awake::Hold;

/// Whether this computer runs on its power adapter, and its battery charge (`None` without a battery).
pub fn power() -> (bool, Option<u8>) {
    #[cfg(windows)]
    {
        use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
        let mut status = SYSTEM_POWER_STATUS::default();
        if unsafe { GetSystemPowerStatus(&mut status) }.is_err() {
            return (true, None);
        }
        // ACLineStatus 0 = on battery; BatteryFlag 128 = no battery; BatteryLifePercent 255 = unknown.
        let battery = (status.BatteryFlag != 128 && status.BatteryLifePercent <= 100).then_some(status.BatteryLifePercent);
        (status.ACLineStatus != 0, battery)
    }
    #[cfg(target_os = "linux")]
    {
        let mut on_power = None;
        let mut battery = None;
        if let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") {
            for entry in entries.flatten() {
                let path = entry.path();
                let read = |name: &str| std::fs::read_to_string(path.join(name)).map(|s| s.trim().to_string()).unwrap_or_default();
                match read("type").as_str() {
                    "Mains" | "USB" => {
                        if read("online") == "1" {
                            on_power = Some(true);
                        } else if on_power.is_none() {
                            on_power = Some(false);
                        }
                    }
                    "Battery" if read("scope") != "Device" => battery = read("capacity").parse().ok(),
                    _ => {}
                }
            }
        }
        // A desktop without a battery reports no adapter at all: it is on power.
        (on_power.unwrap_or(true) || battery.is_none(), battery)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        (true, None)
    }
}

/// The sleep block that is held now, if any.
#[derive(Default)]
pub struct Holder {
    held: Option<(Hold, Inner)>,
}

#[cfg(windows)]
type Inner = std::sync::mpsc::Sender<()>;
#[cfg(target_os = "linux")]
type Inner = std::process::Child;
#[cfg(not(any(windows, target_os = "linux")))]
type Inner = ();

impl Holder {
    /// Holds `hold` (or releases with `Hold::None`); the same hold again changes nothing.
    pub fn set(&mut self, hold: Hold) {
        if self.held.as_ref().map(|(h, _)| *h) == Some(hold) || (hold == Hold::None && self.held.is_none()) {
            return;
        }
        self.release();
        if hold == Hold::None {
            return;
        }
        if let Some(inner) = acquire(hold) {
            self.held = Some((hold, inner));
        }
    }

    fn release(&mut self) {
        if let Some((_, inner)) = self.held.take() {
            stop(inner);
        }
    }
}

#[cfg(target_os = "linux")]
fn stop(mut child: Inner) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Windows: dropping the sender ends the thread, which clears its execution state.
#[cfg(not(target_os = "linux"))]
fn stop(_inner: Inner) {}

impl Drop for Holder {
    fn drop(&mut self) {
        self.release();
    }
}

#[cfg(windows)]
fn acquire(_hold: Hold) -> Option<Inner> {
    use windows::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED};
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    // The state belongs to the thread that set it, so a thread of its own holds it until the sender goes. Windows has
    // no "keep awake with the lid closed" here: that follows the power plan's lid setting, for both holds.
    std::thread::Builder::new()
        .name("nook-keep-awake".into())
        .spawn(move || {
            unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) };
            let _ = rx.recv();
            unsafe { SetThreadExecutionState(ES_CONTINUOUS) };
        })
        .ok()?;
    Some(tx)
}

#[cfg(target_os = "linux")]
fn acquire(hold: Hold) -> Option<Inner> {
    // `sleep` also blocks suspend from the lid, as the Mac does on power; `idle` only the idle timer.
    let what = if hold == Hold::System { "idle:sleep:handle-lid-switch" } else { "idle" };
    std::process::Command::new("systemd-inhibit")
        .args([
            &format!("--what={what}"),
            "--who=Nook",
            "--why=Keeps this computer reachable for your phone",
            "--mode=block",
            "sleep",
            "infinity",
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()
}

#[cfg(not(any(windows, target_os = "linux")))]
fn acquire(_hold: Hold) -> Option<Inner> {
    Some(())
}
