//! Updates for a downloaded Nook on Windows and Linux (`AppUpdater` for release builds on the Mac). The rules live in
//! `nook_core::updates`; this module asks GitHub, downloads, checks the signature, and puts the new version in place:
//!
//! - Windows (Nook's own setup): the signed `Nook-<version>-Windows-setup.exe` runs as a passive update
//!   (`WINDOWS_SETUP_ARGS`). It shows a progress window, keeps the shortcuts and your data, and starts Nook again.
//! - Linux AppImage: the new AppImage replaces the file that runs, and Nook starts it once this one has quit.
//! - `.msi` and `.deb`: the package manager updates them, so Nook shows the release with a download link.
//!
//! Nook checks 20 seconds after launch and then every 4 minutes (a conditional request: an unchanged list is a `304`).
//! Installing is always your click. The interface reads `update_status` and follows the `update-changed` event.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use nook_core::i18n::{tr, trf};
use nook_core::paths;
use nook_core::updates::{
    self, IncomingChange, InstallKind, PolicySource, ReleaseBuild, ReleaseCandidate, ReleaseCheck, UpdateChannel, UpdatePolicy,
    UpdateReceipt, UpdateSignature, UpdateStep,
};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

const EVENT: &str = "update-changed";

/// What you chose in Settings › Maintenance, kept in `Updates/prefs.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Prefs {
    auto_check: bool,
    /// None: the build's own channel (a beta follows betas).
    channel: Option<UpdateChannel>,
}

impl Default for Prefs {
    fn default() -> Self {
        Self { auto_check: true, channel: None }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    /// This build does not update itself (not a release build, or installed by a package manager).
    Unavailable,
    Idle,
    Checking,
    UpToDate,
    Available,
    Installing,
    /// Downloaded and verified; waiting for your Restart because agents are still working.
    ReadyToRestart,
    Failed,
}

#[derive(Default)]
struct Inner {
    prefs: Prefs,
    phase: Option<Phase>,
    step: Option<UpdateStep>,
    progress: Option<f64>,
    candidate: Option<ReleaseCandidate>,
    manual: Option<(String, Option<String>)>,
    last_checked: Option<DateTime<Utc>>,
    problem: Option<String>,
    failure: Option<String>,
    checking: bool,
    /// The last list with its address and `ETag`.
    etag: Option<(String, String, String)>,
    receipt: Option<UpdateReceipt>,
    prepared: Option<Prepared>,
}

pub struct Updater {
    build: Option<ReleaseBuild>,
    kind: InstallKind,
    /// What an administrator (or `NOOK_DISABLE_UPDATES`) allows.
    policy: UpdatePolicy,
    inner: Mutex<Inner>,
}

/// A newer release, as the panel shows it.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    version: String,
    title: String,
    page: Option<String>,
    changes: Vec<IncomingChange>,
    change_count: usize,
    size: u64,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Manual {
    version: String,
    page: Option<String>,
}

/// Everything Settings and the footer button show.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    phase: Phase,
    /// Why there is no updater, when `phase` is `unavailable`.
    unavailable_reason: Option<String>,
    version: String,
    install_kind: InstallKind,
    step: Option<UpdateStep>,
    progress: Option<f64>,
    candidate: Option<Candidate>,
    manual: Option<Manual>,
    last_checked: Option<DateTime<Utc>>,
    checking: bool,
    problem: Option<String>,
    failure: Option<String>,
    channel: UpdateChannel,
    auto_check: bool,
    policy: UpdatePolicy,
    /// What the update this build came from brought, until you close it.
    receipt: Option<UpdateReceipt>,
}

fn folder() -> PathBuf {
    paths::support_directory().join("Updates")
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn write_json<T: Serialize>(path: &Path, value: &T) {
    if let Ok(bytes) = serde_json::to_vec_pretty(value) {
        let _ = paths::write_atomic(path, &bytes);
    }
}

/// The setup that installed this version is done with: remove what is left in the updates folder.
fn remove_downloads() {
    if let Ok(entries) = std::fs::read_dir(folder()) {
        for entry in entries.flatten() {
            if entry.path().extension().is_some_and(|e| e == "exe" || e == "msi" || e == "deb") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

fn detect_kind() -> InstallKind {
    let exe = std::env::current_exe().ok();
    let has_uninstaller = exe.as_ref().and_then(|exe| exe.parent().map(|dir| dir.join("uninstall.exe").is_file())).unwrap_or(false);
    let appimage = std::env::var("APPIMAGE").ok();
    // Only asked on Linux without an AppImage: is the executable a file of an installed .deb?
    let dpkg_owned = cfg!(target_os = "linux")
        && appimage.is_none()
        && exe.is_some_and(|exe| {
            std::process::Command::new("dpkg-query")
                .arg("-S")
                .arg(exe)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        });
    InstallKind::detect(std::env::consts::OS, has_uninstaller, appimage.as_deref(), dpkg_owned)
}

/// The policy from the environment and what an administrator set: the registry on Windows, `/etc/nook/policy.json`
/// on Linux.
fn read_policy() -> UpdatePolicy {
    let env = std::env::var("NOOK_DISABLE_UPDATES").ok();
    UpdatePolicy::resolve(env.as_deref(), managed_policy())
}

#[cfg(target_os = "windows")]
fn managed_policy() -> Result<Option<(bool, bool)>, ()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let read = |root: &str, name: &str| -> Option<bool> {
        let output = std::process::Command::new("reg")
            .args(["query", &format!(r"{root}\{}", updates::WINDOWS_POLICY_KEY), "/v", name])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .ok()?;
        UpdatePolicy::parse_reg_query(&String::from_utf8_lossy(&output.stdout), name)
    };
    // The machine's policy wins over the user's, as with any Windows policy.
    let value = |name: &str| read("HKLM", name).or_else(|| read("HKCU", name));
    let (off, beta) = (value("DisableUpdates"), value("DisableBetaChannel"));
    Ok((off.is_some() || beta.is_some()).then(|| (off.unwrap_or(false), beta.unwrap_or(false))))
}

#[cfg(target_os = "linux")]
fn managed_policy() -> Result<Option<(bool, bool)>, ()> {
    let path = Path::new(updates::LINUX_POLICY_PATH);
    if !path.exists() {
        return Ok(None);
    }
    let text = std::fs::read_to_string(path).map_err(|_| ())?;
    UpdatePolicy::parse_json(Some(&text))
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn managed_policy() -> Result<Option<(bool, bool)>, ()> {
    Ok(None)
}

impl Updater {
    fn load() -> Self {
        let build = updates::this_build();
        let kind = detect_kind();
        let policy = read_policy();
        let prefs = read_json::<Prefs>(&folder().join("prefs.json")).unwrap_or_default();
        let mut inner = Inner { prefs, ..Default::default() };
        // The update this build came from: show what it brought, or say that it did not take.
        let receipt_path = folder().join("receipt.json");
        if let (Some(build), Some(receipt)) = (&build, read_json::<UpdateReceipt>(&receipt_path)) {
            let running = build.version.to_string();
            if let Some(promised) = receipt.not_applied(&running, Utc::now()) {
                inner.failure = Some(trf(
                    "Nook is herstart, maar versie {version} is niet geïnstalleerd. Probeer het opnieuw of download hem van de releasepagina.",
                    "Nook restarted, but version {version} was not installed. Try again or download it from the releases page.",
                    &[("version", &promised)],
                ));
                inner.phase = Some(Phase::Failed);
                let _ = std::fs::remove_file(&receipt_path);
            } else if receipt.to == running {
                inner.receipt = Some(receipt);
                remove_downloads();
            } else {
                let _ = std::fs::remove_file(&receipt_path);
            }
        }
        Self { build, kind, policy, inner: Mutex::new(inner) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn unavailable_reason(&self) -> Option<String> {
        if self.policy.disabled {
            return Some(
                match self.policy.source {
                    Some(PolicySource::Environment) => {
                        tr("Updates staan uit door NOOK_DISABLE_UPDATES.", "Updates are turned off by NOOK_DISABLE_UPDATES.")
                    }
                    Some(PolicySource::Unreadable) => tr(
                        "Updates staan uit: Nook kan het beleid van je beheerder niet lezen. Vraag je beheerder om hulp.",
                        "Updates are off: Nook cannot read your administrator's policy. Ask your administrator for help.",
                    ),
                    _ => tr(
                        "Je beheerder heeft updates op deze computer uitgezet.",
                        "Your administrator turned updates off on this computer.",
                    ),
                }
                .to_string(),
            );
        }
        if self.build.is_none() {
            return Some(
                tr(
                    "Deze versie is niet door de releaseworkflow gebouwd en werkt zichzelf niet bij.",
                    "This version was not built by the release workflow and does not update itself.",
                )
                .to_string(),
            );
        }
        match self.kind {
            InstallKind::Package => Some(
                tr(
                    "Nook is op een andere manier geïnstalleerd dan met de setup, .msi, AppImage of .deb, en werkt zichzelf daarom niet bij. De nieuwste staat op de releasepagina.",
                    "Nook was installed some other way than the setup, .msi, AppImage or .deb, so it does not update itself. The newest one is on the releases page.",
                )
                .to_string(),
            ),
            InstallKind::Unsupported => Some(tr("Op dit platform werkt Nook zichzelf nog niet bij.", "Nook does not update itself on this platform yet.").to_string()),
            _ => None,
        }
    }

    fn channel(&self, inner: &Inner) -> UpdateChannel {
        let wanted =
            inner.prefs.channel.or_else(|| self.build.as_ref().map(ReleaseBuild::default_channel)).unwrap_or(UpdateChannel::Stable);
        self.policy.channel(wanted)
    }

    /// Whether Nook looks for releases at all: a release build, also when a package manager installed it (then it only
    /// links to the newer release).
    fn checks(&self) -> bool {
        self.build.is_some() && self.kind != InstallKind::Unsupported && !self.policy.disabled
    }

    pub fn status(&self) -> UpdateStatus {
        let inner = self.lock();
        let reason = self.unavailable_reason();
        let phase = match inner.phase {
            Some(phase) => phase,
            _ if self.policy.disabled => Phase::Unavailable,
            None if !self.checks() || self.kind.platform().is_none() => Phase::Unavailable,
            None => Phase::Idle,
        };
        UpdateStatus {
            phase,
            unavailable_reason: reason,
            version: self.build.as_ref().map(|b| b.version.to_string()).unwrap_or_default(),
            install_kind: self.kind.clone(),
            step: inner.step,
            progress: inner.progress,
            candidate: inner.candidate.as_ref().map(|c| Candidate {
                version: c.version.to_string(),
                title: c.title.clone(),
                page: c.page.clone(),
                changes: c.changes.clone(),
                change_count: c.change_count,
                size: c.installer.size,
            }),
            manual: inner.manual.as_ref().map(|(version, page)| Manual { version: version.clone(), page: page.clone() }),
            last_checked: inner.last_checked,
            checking: inner.checking,
            problem: inner.problem.clone(),
            failure: inner.failure.clone(),
            channel: self.channel(&inner),
            auto_check: inner.prefs.auto_check,
            policy: self.policy.clone(),
            receipt: inner.receipt.clone(),
        }
    }
}

fn emit(app: &AppHandle) {
    if let Some(updater) = app.try_state::<Updater>() {
        let _ = app.emit(EVENT, updater.status());
    }
}

pub fn setup(app: &AppHandle) {
    app.manage(Updater::load());
}

/// The checks in the background: 20 seconds after launch, then every 4 minutes while automatic checks are on.
pub fn start(app: &AppHandle) {
    let Some(updater) = app.try_state::<Updater>() else { return };
    if !updater.checks() {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(updates::FIRST_CHECK_SECONDS)).await;
        loop {
            let auto = app.state::<Updater>().lock().prefs.auto_check;
            if auto {
                check(&app).await;
            }
            tokio::time::sleep(Duration::from_secs(updates::CHECK_INTERVAL_SECONDS)).await;
        }
    });
}

fn client() -> Result<reqwest::Client, String> {
    let version = updates::this_build().map(|b| b.version.to_string()).unwrap_or_else(|| "dev".into());
    reqwest::Client::builder()
        .user_agent(format!("Nook/{version}"))
        .connect_timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())
}

/// Asks GitHub for the releases. Quiet when it fails: Settings shows why, a later check tries again.
async fn check(app: &AppHandle) {
    let updater = app.state::<Updater>();
    let Some(build) = updater.build.clone() else { return };
    let etag = {
        let mut inner = updater.lock();
        if inner.checking || matches!(inner.phase, Some(Phase::Installing | Phase::ReadyToRestart)) {
            return;
        }
        inner.checking = true;
        if inner.candidate.is_none() && inner.phase != Some(Phase::Failed) {
            inner.phase = Some(Phase::Checking);
        }
        inner.etag.clone()
    };
    emit(app);

    // The feed first (a static file, no rate limit); GitHub's API when it is not there yet or fails.
    let result = match fetch_list(&updater, &build.feed_url(), etag.as_ref(), false).await {
        Ok(body) => Ok(body),
        Err(_) => fetch_list(&updater, &build.releases_url(), etag.as_ref(), true).await,
    };

    {
        let mut inner = updater.lock();
        inner.checking = false;
        inner.last_checked = Some(Utc::now());
        let installing = matches!(inner.phase, Some(Phase::Installing | Phase::ReadyToRestart));
        let failed = inner.phase == Some(Phase::Failed);
        match result {
            Ok(body) => {
                inner.problem = None;
                // A package manager's copy only hears about the release; Nook's own copy can install it.
                let platform = updater.kind.platform().unwrap_or(updates::UpdatePlatform::Windows);
                let channel = updater.channel(&inner);
                let found = updates::check(&updates::GitHubRelease::list(&body), &build, platform, Some(channel));
                inner.manual = None;
                inner.candidate = None;
                match found {
                    ReleaseCheck::UpToDate => {}
                    ReleaseCheck::Available(candidate) if updater.kind.platform().is_some() => {
                        inner.receipt = None;
                        inner.candidate = Some(candidate);
                    }
                    ReleaseCheck::Available(candidate) => {
                        inner.manual = Some((candidate.version.to_string(), candidate.page));
                    }
                    ReleaseCheck::Unsigned { version, page } => inner.manual = Some((version.to_string(), page)),
                }
                if !installing && !failed {
                    inner.phase = Some(if inner.candidate.is_some() {
                        Phase::Available
                    } else if updater.kind.platform().is_some() {
                        Phase::UpToDate
                    } else {
                        Phase::Unavailable
                    });
                }
            }
            Err(problem) => {
                inner.problem = Some(problem);
                if !installing && !failed {
                    inner.phase = Some(if inner.candidate.is_some() {
                        Phase::Available
                    } else if updater.kind.platform().is_some() {
                        Phase::Idle
                    } else {
                        Phase::Unavailable
                    });
                }
            }
        }
    }
    emit(app);
}

/// One answer with the release list from `url`, conditional on the last one from the same address.
async fn fetch_list(updater: &Updater, url: &str, last: Option<&(String, String, String)>, api: bool) -> Result<String, String> {
    let mut request = client()?.get(url).timeout(Duration::from_secs(30));
    if api {
        request = request.header("Accept", "application/vnd.github+json");
    }
    let cached = last.filter(|(from, _, _)| from == url);
    if let Some((_, tag, _)) = cached {
        request = request.header("If-None-Match", tag);
    }
    let response = request.send().await.map_err(|e| e.to_string())?;
    let status = response.status().as_u16();
    if status == 304 {
        if let Some((_, _, body)) = cached {
            return Ok(body.clone());
        }
    }
    if status != 200 {
        return Err(trf("GitHub antwoordde met {status}.", "GitHub answered with {status}.", &[("status", &status)]));
    }
    let tag = response.headers().get("ETag").and_then(|v| v.to_str().ok()).map(str::to_string);
    let body = response.text().await.map_err(|e| e.to_string())?;
    // A feed that is not a list (an error page) counts as missing, so the API is asked instead.
    if !body.trim_start().starts_with('[') {
        return Err(tr("Onverwacht antwoord van GitHub.", "Unexpected answer from GitHub.").to_string());
    }
    updater.lock().etag = tag.map(|tag| (url.to_string(), tag, body.clone()));
    Ok(body)
}

fn set_step(app: &AppHandle, step: UpdateStep, progress: Option<f64>) {
    {
        let updater = app.state::<Updater>();
        let mut inner = updater.lock();
        inner.step = Some(step);
        inner.progress = progress;
    }
    emit(app);
}

/// Downloads `url` into memory, reporting progress for the installer.
async fn download(app: &AppHandle, url: &str, expected: u64, report: bool) -> Result<Vec<u8>, String> {
    let mut response = client()?.get(url).timeout(Duration::from_secs(30 * 60)).send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(trf("De download gaf {status}.", "The download returned {status}.", &[("status", &response.status().as_u16())]));
    }
    let total = response.content_length().unwrap_or(expected).max(1);
    let mut data = Vec::with_capacity(total.min(1_000_000_000) as usize);
    let mut last = 0.0;
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        data.extend_from_slice(&chunk);
        if data.len() as u64 > 1_000_000_000 {
            return Err(tr("De download is groter dan verwacht.", "The download is larger than expected.").to_string());
        }
        let progress = (data.len() as f64 / total as f64).min(1.0);
        if report && progress - last >= 0.01 {
            last = progress;
            set_step(app, UpdateStep::Download, Some(progress));
        }
    }
    Ok(data)
}

/// The verified update, kept until Nook restarts into it: a retry after a failed restart does not download again, and
/// an update that waits for agents to finish restarts straight away when you press Restart.
#[derive(Clone)]
struct Prepared {
    version: String,
    /// The setup in `Updates/`, or the new AppImage next to the running one (swapped in on restart).
    file: PathBuf,
    signature: Vec<u8>,
    receipt: UpdateReceipt,
    /// A .deb is installed before the restart; a retry does not install it again.
    installed: bool,
}

/// Agents that are still working; a restart stops them (they can be resumed afterwards).
fn working_agents(app: &AppHandle) -> usize {
    app.try_state::<crate::workspace::WorkspaceState>()
        .map(|w| w.manager.runs().iter().filter(|r| r.status.is_active()).count())
        .unwrap_or(0)
}

/// Download → verify → stage → restart (or wait for you when agents are working). Returns only on failure or while
/// waiting; on a restart Nook quits.
async fn install(app: &AppHandle) -> Result<(), String> {
    let updater = app.state::<Updater>();
    let build = updater.build.clone().ok_or_else(|| tr("Geen releaseversie.", "Not a release build.").to_string())?;
    let public_key = build.public_key.clone().ok_or_else(|| {
        tr("Deze versie heeft geen sleutel om updates te controleren.", "This version has no key to check updates with.").to_string()
    })?;
    let candidate = updater.lock().candidate.clone().ok_or_else(|| tr("Er is geen update.", "There is no update.").to_string())?;
    let version = candidate.version.to_string();

    // A download that was verified before (the restart failed or waited) is checked again from disk, not fetched again.
    let staged = updater.lock().prepared.clone().filter(|p| p.version == version);
    let reusable = staged.filter(|p| std::fs::read(&p.file).is_ok_and(|data| UpdateSignature::verify(&data, &p.signature, &public_key)));
    let prepared = match reusable {
        Some(prepared) => prepared,
        None => {
            set_step(app, UpdateStep::Download, Some(0.0));
            let installer = download(app, &candidate.installer.url, candidate.installer.size, true).await?;
            let signature = download(app, &candidate.signature.url, candidate.signature.size, false).await?;

            set_step(app, UpdateStep::Verify, None);
            if !UpdateSignature::verify(&installer, &signature, &public_key) {
                return Err(tr(
                    "De handtekening van de download klopt niet. Nook heeft hem niet geïnstalleerd.",
                    "The download's signature does not match. Nook did not install it.",
                )
                .to_string());
            }
            let name = updates::download_name(&candidate.installer.name)
                .ok_or_else(|| tr("Onverwachte bestandsnaam.", "Unexpected file name.").to_string())?;

            set_step(app, UpdateStep::Install, None);
            let file = match &updater.kind {
                InstallKind::WindowsSetup | InstallKind::WindowsMsi | InstallKind::Deb => {
                    let path = folder().join(name);
                    paths::write_atomic(&path, &installer).map_err(|e| e.to_string())?;
                    path
                }
                InstallKind::AppImage { path } => stage_appimage(Path::new(path), &installer)?,
                _ => return Err(tr("Deze installatie werkt zichzelf niet bij.", "This installation does not update itself.").to_string()),
            };
            let receipt = UpdateReceipt {
                from: build.version.to_string(),
                to: version.clone(),
                changes: candidate.changes.clone(),
                installed_at: Utc::now(),
            };
            let prepared = Prepared { version, file, signature, receipt, installed: false };
            updater.lock().prepared = Some(prepared.clone());
            prepared
        }
    };

    // A .deb goes in now (pkexec asks for your password); the running Nook keeps its open copy until the restart.
    let prepared = if updater.kind == InstallKind::Deb && !prepared.installed {
        set_step(app, UpdateStep::Install, None);
        install_deb(&prepared.file).await?;
        let prepared = Prepared { installed: true, ..prepared };
        updater.lock().prepared = Some(prepared.clone());
        prepared
    } else {
        prepared
    };

    // As on the Mac: agents that are working are not stopped behind your back; the update waits for your Restart.
    if working_agents(app) > 0 {
        {
            let mut inner = updater.lock();
            inner.phase = Some(Phase::ReadyToRestart);
            inner.step = Some(UpdateStep::Restart);
            inner.progress = None;
        }
        emit(app);
        return Ok(());
    }
    restart_into(app, &prepared)
}

/// Hands over to the new version: stops agents and the WhatsApp gateway first (the Windows setup closes a Nook that
/// still runs, which would skip that), then starts the setup or the new AppImage, and quits.
fn restart_into(app: &AppHandle, prepared: &Prepared) -> Result<(), String> {
    let updater = app.state::<Updater>();
    set_step(app, UpdateStep::Restart, None);
    let receipt_path = folder().join("receipt.json");
    if let InstallKind::AppImage { path } = &updater.kind {
        std::fs::rename(&prepared.file, path)
            .map_err(|e| trf("Kon de AppImage niet vervangen: {error}", "Could not replace the AppImage: {error}", &[("error", &e)]))?;
    }
    write_json(&receipt_path, &UpdateReceipt { installed_at: Utc::now(), ..prepared.receipt.clone() });
    crate::workspace::shutdown(app);
    crate::connectors::shutdown(app);
    if let Some(workspace) = app.try_state::<crate::workspace::WorkspaceState>() {
        workspace.manager.flush();
    }
    let started = match &updater.kind {
        InstallKind::WindowsSetup => run_setup(&prepared.file),
        InstallKind::WindowsMsi => run_msi(&prepared.file),
        InstallKind::AppImage { path } => relaunch(path),
        InstallKind::Deb => match std::env::current_exe() {
            Ok(exe) => relaunch(&exe.to_string_lossy()),
            Err(e) => Err(e.to_string()),
        },
        _ => Err(tr("Deze installatie werkt zichzelf niet bij.", "This installation does not update itself.").to_string()),
    };
    if let Err(e) = started {
        let _ = std::fs::remove_file(&receipt_path);
        return Err(trf(
            "{error} Agents en WhatsApp zijn gestopt: start Nook opnieuw om verder te gaan.",
            "{error} Agents and WhatsApp were stopped: restart Nook to carry on.",
            &[("error", &e)],
        ));
    }
    // The setup (or the shell loop for the AppImage) waits for this process to end, then starts the new version.
    app.exit(0);
    Ok(())
}

#[cfg(target_os = "windows")]
fn run_setup(path: &Path) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    std::process::Command::new(path)
        .args(updates::WINDOWS_SETUP_ARGS)
        .creation_flags(DETACHED_PROCESS)
        .spawn()
        .map(|_| ())
        .map_err(|e| trf("Kon de setup niet starten: {error}", "Could not start the setup: {error}", &[("error", &e)]))
}

#[cfg(target_os = "windows")]
fn run_msi(path: &Path) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    std::process::Command::new("msiexec.exe")
        .args(updates::msi_args(&path.to_string_lossy()))
        .creation_flags(DETACHED_PROCESS)
        .spawn()
        .map(|_| ())
        .map_err(|e| trf("Kon de setup niet starten: {error}", "Could not start the setup: {error}", &[("error", &e)]))
}

#[cfg(not(target_os = "windows"))]
fn run_msi(_path: &Path) -> Result<(), String> {
    run_setup(_path)
}

/// Installs the .deb as root through pkexec (a system password dialog), and waits for it.
async fn install_deb(path: &Path) -> Result<(), String> {
    let has_apt = Path::new("/usr/bin/apt-get").exists();
    let command = updates::deb_command(&path.to_string_lossy(), has_apt);
    let output = tokio::process::Command::new(&command[0])
        .args(&command[1..])
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| trf("Kon de installatie niet starten: {error}", "Could not start the installation: {error}", &[("error", &e)]))?;
    match output.status.code() {
        Some(0) => Ok(()),
        // pkexec: the dialog was dismissed (126) or no one may authorise (127).
        Some(126 | 127) => Err(tr(
            "De installatie is geannuleerd: zonder je wachtwoord kan Nook het pakket niet bijwerken.",
            "The installation was cancelled: without your password Nook cannot update the package.",
        )
        .to_string()),
        _ => {
            let detail = String::from_utf8_lossy(&output.stderr);
            let last = detail.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
            Err(trf(
                "Het pakket kon niet worden geïnstalleerd: {error}",
                "The package could not be installed: {error}",
                &[("error", &last)],
            ))
        }
    }
}

#[cfg(not(target_os = "windows"))]
fn run_setup(_path: &Path) -> Result<(), String> {
    Err(tr("De Windows-setup draait alleen op Windows.", "The Windows setup only runs on Windows.").to_string())
}

/// Writes the new AppImage next to the running one, ready to be swapped in with a rename on restart (the running
/// process keeps its open copy), so a failure halfway leaves the old one untouched.
fn stage_appimage(target: &Path, data: &[u8]) -> Result<PathBuf, String> {
    let dir = target.parent().ok_or_else(|| tr("Onbekende map.", "Unknown folder.").to_string())?;
    let temp = dir.join(format!(".{}.update", target.file_name().and_then(|n| n.to_str()).unwrap_or("Nook.AppImage")));
    let fail =
        |e: std::io::Error| trf("Kon de AppImage niet vervangen: {error}", "Could not replace the AppImage: {error}", &[("error", &e)]);
    std::fs::write(&temp, data).map_err(fail)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o755)).map_err(fail)?;
    }
    Ok(temp)
}

/// Starts the new AppImage once this process has quit (Nook runs one copy at a time, so it cannot start earlier).
fn relaunch(path: &str) -> Result<(), String> {
    let pid = std::process::id().to_string();
    std::process::Command::new("/bin/sh")
        .args(["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done; exec \"$2\" >/dev/null 2>&1", "nook-update", &pid, path])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| trf("Kon Nook niet opnieuw starten: {error}", "Could not restart Nook: {error}", &[("error", &e)]))
}

// MARK: Commands

#[tauri::command]
pub fn update_status(app: AppHandle) -> Option<UpdateStatus> {
    app.try_state::<Updater>().map(|u| u.status())
}

#[tauri::command]
pub async fn update_check(app: AppHandle) -> Option<UpdateStatus> {
    {
        let updater = app.try_state::<Updater>()?;
        if !updater.checks() {
            return Some(updater.status());
        }
        // "Check now" after a failure: start fresh.
        let mut inner = updater.lock();
        if inner.phase == Some(Phase::Failed) {
            inner.phase = None;
            inner.failure = None;
        }
    }
    check(&app).await;
    update_status(app)
}

#[tauri::command]
pub async fn update_install(app: AppHandle) -> Result<(), String> {
    {
        let updater = app.state::<Updater>();
        let mut inner = updater.lock();
        if matches!(inner.phase, Some(Phase::Installing | Phase::ReadyToRestart)) || inner.candidate.is_none() {
            return Ok(());
        }
        inner.phase = Some(Phase::Installing);
        inner.failure = None;
    }
    emit(&app);
    if let Err(failure) = install(&app).await {
        {
            let updater = app.state::<Updater>();
            let mut inner = updater.lock();
            inner.phase = Some(Phase::Failed);
            inner.failure = Some(failure.clone());
            inner.progress = None;
        }
        emit(&app);
        return Err(failure);
    }
    Ok(())
}

/// "Restart now" for an update that waited for working agents: they stop, and can be resumed after the restart.
#[tauri::command]
pub fn update_restart(app: AppHandle) -> Result<(), String> {
    let prepared = {
        let updater = app.state::<Updater>();
        let inner = updater.lock();
        if inner.phase != Some(Phase::ReadyToRestart) {
            return Ok(());
        }
        inner.prepared.clone()
    };
    let Some(prepared) = prepared else { return Ok(()) };
    if let Err(failure) = restart_into(&app, &prepared) {
        {
            let updater = app.state::<Updater>();
            let mut inner = updater.lock();
            inner.phase = Some(Phase::Failed);
            inner.failure = Some(failure.clone());
        }
        emit(&app);
        return Err(failure);
    }
    Ok(())
}

#[tauri::command]
pub async fn update_set_prefs(app: AppHandle, auto_check: Option<bool>, channel: Option<UpdateChannel>) -> Option<UpdateStatus> {
    let changed_channel = {
        let updater = app.try_state::<Updater>()?;
        let mut inner = updater.lock();
        if let Some(auto) = auto_check {
            inner.prefs.auto_check = auto;
        }
        let channel = channel.map(|c| updater.policy.channel(c));
        let changed = channel.is_some_and(|c| Some(c) != inner.prefs.channel);
        if channel.is_some() {
            inner.prefs.channel = channel;
        }
        write_json(&folder().join("prefs.json"), &inner.prefs);
        changed
    };
    // Picking a channel checks right away, as on the Mac.
    if changed_channel {
        check(&app).await;
    } else {
        emit(&app);
    }
    update_status(app)
}

/// Closes the "what came in" list after an update, and clears a failure.
#[tauri::command]
pub fn update_dismiss(app: AppHandle) -> Option<UpdateStatus> {
    let updater = app.try_state::<Updater>()?;
    {
        let mut inner = updater.lock();
        inner.receipt = None;
        if inner.phase == Some(Phase::Failed) {
            inner.failure = None;
            inner.phase = None;
            if inner.candidate.is_some() {
                inner.phase = Some(Phase::Available);
            }
        }
    }
    let _ = std::fs::remove_file(folder().join("receipt.json"));
    remove_downloads();
    emit(&app);
    Some(updater.status())
}

// MARK: Companion

/// Whether a phone may install updates here: this copy updates itself and nothing turned updates off.
pub fn companion_can_install(app: &AppHandle) -> bool {
    app.try_state::<Updater>().is_some_and(|u| u.checks() && u.kind.platform().is_some())
}

/// The update the phone's home shows; None when there is nothing to install.
pub fn companion_offer(app: &AppHandle) -> Option<nook_core::companion::home_digest::UpdateOffer> {
    let updater = app.try_state::<Updater>()?;
    let inner = updater.lock();
    let candidate = inner.candidate.as_ref()?;
    let state = match inner.phase {
        Some(Phase::Installing) => "installing",
        Some(Phase::ReadyToRestart) => "readyToRestart",
        Some(Phase::Failed) => "failed",
        _ => "available",
    };
    Some(nook_core::companion::home_digest::UpdateOffer {
        version: candidate.version.to_string(),
        state: state.into(),
        changes: u32::try_from(candidate.change_count).unwrap_or(u32::MAX),
        progress: (inner.phase == Some(Phase::Installing)).then_some(inner.progress).flatten(),
    })
}

/// `requestUpdate` from the phone: Settings › Maintenance opens on this computer, where the update waits.
pub fn companion_show(app: &AppHandle) -> &'static str {
    if !companion_can_install(app) {
        return "unavailable";
    }
    if app.state::<Updater>().lock().candidate.is_none() {
        return "none";
    }
    #[cfg(desktop)]
    crate::platform::desktop::show_main(app, "settings:maintenance");
    "available"
}

/// `installUpdate` from the phone: starts the install (in the background, so the answer comes right away), or restarts
/// into an update that waited for agents.
pub fn companion_install(app: &AppHandle) -> &'static str {
    if !companion_can_install(app) {
        return "unavailable";
    }
    let phase = {
        let updater = app.state::<Updater>();
        let inner = updater.lock();
        if inner.candidate.is_none() {
            return "none";
        }
        inner.phase
    };
    match phase {
        Some(Phase::Installing) => "installing",
        Some(Phase::ReadyToRestart) => {
            // A short delay, so the answer reaches the phone before Nook quits.
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let _ = update_restart(app);
            });
            "restarting"
        }
        _ => {
            // Agents that work make the install wait for a Restart, as when you click Install here.
            let waiting = working_agents(app) > 0;
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let _ = update_install(app).await;
            });
            if waiting {
                "waiting"
            } else {
                "installing"
            }
        }
    }
}
