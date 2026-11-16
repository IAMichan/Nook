//! Keeps Nook running so the phone can always reach this computer, as t3code runs its server as a background service.
//! Windows: a task in Task Scheduler that starts Nook at sign-in and again within a minute when it stopped (a repeating
//! trigger with `IgnoreNew`; a second Nook ends at once in the single-instance check). Linux: a systemd user service in
//! the graphical session with `Restart=on-failure`. Both start Nook with `--background`, which opens no window.

/// The argument the task starts Nook with: no window, and a second start does not bring the first one forward.
pub const BACKGROUND_ARG: &str = "--background";

/// Whether this platform can keep Nook running.
pub fn supported() -> bool {
    cfg!(any(windows, target_os = "linux"))
}

/// The program to start: the AppImage itself on Linux when Nook runs from one (its inner path changes per start).
fn program() -> Option<String> {
    #[cfg(target_os = "linux")]
    if let Ok(appimage) = std::env::var("APPIMAGE") {
        if !appimage.is_empty() {
            return Some(appimage);
        }
    }
    std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned())
}

#[cfg(windows)]
mod imp {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    fn schtasks(args: &[&str]) -> Result<String, String> {
        let output = Command::new("schtasks").args(args).creation_flags(CREATE_NO_WINDOW).output().map_err(|e| e.to_string())?;
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
        }
    }

    fn user() -> String {
        let name = std::env::var("USERNAME").unwrap_or_default();
        match std::env::var("USERDOMAIN") {
            Ok(domain) if !domain.is_empty() => format!("{domain}\\{name}"),
            _ => name,
        }
    }

    fn task_name() -> String {
        let name: String = std::env::var("USERNAME").unwrap_or_default().chars().filter(|c| c.is_alphanumeric() || *c == '-').collect();
        format!("Nook-{name}")
    }

    fn escape(text: &str) -> String {
        text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
    }

    /// The task, as t3code writes its own: started at sign-in and every minute, a new start ignored while one runs, no
    /// time limit, not stopped on battery, at normal priority. No XML declaration: schtasks refuses `encoding="UTF-8"`
    /// but reads undeclared XML as UTF-8.
    pub fn task_xml(program: &str, user: &str) -> String {
        format!(
            r#"<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keeps Nook running so your phone can reach this PC.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <UserId>{user}</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT1M</Interval>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{program}</Command>
      <Arguments>{arg}</Arguments>
    </Exec>
  </Actions>
</Task>
"#,
            user = escape(user),
            program = escape(program),
            arg = super::BACKGROUND_ARG,
        )
    }

    pub fn installed() -> bool {
        schtasks(&["/Query", "/TN", &task_name()]).is_ok()
    }

    pub fn install(program: &str) -> Result<(), String> {
        let path = std::env::temp_dir().join(format!("nook-task-{}.xml", std::process::id()));
        std::fs::write(&path, task_xml(program, &user())).map_err(|e| e.to_string())?;
        let path_text = path.to_string_lossy().into_owned();
        let result = schtasks(&["/Create", "/XML", &path_text, "/TN", &task_name(), "/F"]).map(|_| ());
        let _ = std::fs::remove_file(&path);
        result
    }

    pub fn uninstall() -> Result<(), String> {
        if !installed() {
            return Ok(());
        }
        schtasks(&["/Delete", "/TN", &task_name(), "/F"]).map(|_| ())
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::path::PathBuf;
    use std::process::Command;

    const UNIT: &str = "nook.service";

    fn unit_path() -> Option<PathBuf> {
        Some(dirs::config_dir()?.join("systemd/user").join(UNIT))
    }

    fn systemctl(args: &[&str]) -> Result<(), String> {
        let output = Command::new("systemctl").arg("--user").args(args).output().map_err(|e| e.to_string())?;
        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
        }
    }

    /// Part of the graphical session, so it starts with the desktop (and its display) and stops with it.
    pub fn unit(program: &str) -> String {
        let quoted = program.replace('\\', "\\\\").replace('"', "\\\"");
        format!(
            "[Unit]\nDescription=Nook (keeps it running so your phone can reach this computer)\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n[Service]\nExecStart=\"{quoted}\" {arg}\nRestart=on-failure\nRestartSec=10\n\n[Install]\nWantedBy=graphical-session.target\n",
            arg = super::BACKGROUND_ARG
        )
    }

    pub fn installed() -> bool {
        Command::new("systemctl").args(["--user", "is-enabled", "--quiet", UNIT]).status().is_ok_and(|s| s.success())
    }

    pub fn install(program: &str) -> Result<(), String> {
        let path = unit_path().ok_or("No configuration folder.")?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(&path, unit(program)).map_err(|e| e.to_string())?;
        systemctl(&["daemon-reload"])?;
        systemctl(&["enable", UNIT])
    }

    pub fn uninstall() -> Result<(), String> {
        let _ = systemctl(&["disable", UNIT]);
        if let Some(path) = unit_path() {
            let _ = std::fs::remove_file(path);
        }
        systemctl(&["daemon-reload"])
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod imp {
    pub fn installed() -> bool {
        false
    }
    pub fn install(_: &str) -> Result<(), String> {
        Err("Not on this platform.".into())
    }
    pub fn uninstall() -> Result<(), String> {
        Ok(())
    }
}

/// Whether the task is there: asked once (a `schtasks` or `systemctl` process), then kept, since only `set` changes it.
pub fn installed() -> bool {
    supported() && known().load(std::sync::atomic::Ordering::SeqCst)
}

fn known() -> &'static std::sync::atomic::AtomicBool {
    static KNOWN: std::sync::OnceLock<std::sync::atomic::AtomicBool> = std::sync::OnceLock::new();
    KNOWN.get_or_init(|| std::sync::atomic::AtomicBool::new(supported() && imp::installed()))
}

/// Turns keeping Nook running on or off.
pub fn set(on: bool) -> Result<(), String> {
    if on {
        imp::install(&program().ok_or("Nook's own path is unknown.")?)?;
    } else {
        imp::uninstall()?;
    }
    known().store(on, std::sync::atomic::Ordering::SeqCst);
    Ok(())
}

#[cfg(test)]
mod tests {
    #[cfg(windows)]
    #[test]
    fn task_restarts_nook_in_the_background() {
        let xml = super::imp::task_xml(r"C:\Program Files\Nook\nook.exe", r"PC\Jo & Co");
        assert!(xml.starts_with("<Task "), "no XML declaration");
        assert!(xml.contains("<Interval>PT1M</Interval>") && xml.contains("<MultipleInstancesPolicy>IgnoreNew"));
        assert!(xml.contains(r"<UserId>PC\Jo &amp; Co</UserId>"));
        assert!(xml.contains("<Arguments>--background</Arguments>"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn unit_restarts_nook_in_the_session() {
        let unit = super::imp::unit("/opt/Nook/nook");
        assert!(unit.contains("ExecStart=\"/opt/Nook/nook\" --background"));
        assert!(unit.contains("Restart=on-failure") && unit.contains("WantedBy=graphical-session.target"));
    }
}
