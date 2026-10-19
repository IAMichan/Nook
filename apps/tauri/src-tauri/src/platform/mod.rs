//! De platformlaag: wat Windows, Linux en Android elk anders doen, achter de traits uit `nook_core::platform`.

pub mod secrets;

#[cfg(desktop)]
pub mod desktop;

use nook_core::platform::Capabilities;

pub fn capabilities() -> Capabilities {
    let os = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "android") {
        "android"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    };
    let desktop = cfg!(desktop);
    Capabilities {
        os: os.into(),
        desktop,
        screen_reading: false,
        global_shortcuts: desktop,
        tray: desktop,
        terminals: desktop,
        local_agents: desktop,
        media: false,
    }
}
