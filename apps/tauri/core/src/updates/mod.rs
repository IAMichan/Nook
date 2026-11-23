//! Updates for a downloaded build from GitHub Releases (`ReleaseUpdateCore` on the Mac). Nook asks GitHub for a newer
//! release on its channel, downloads this platform's installer, checks the Ed25519 signature that the release workflow
//! made with the project's private key (the same key and `.sig` format as the Mac's `.zip`) against the public key the
//! build carries, and only then runs it. Everything here is plain logic; downloading and installing live in
//! `src-tauri/src/updates.rs`.

use std::cmp::Ordering;
use std::collections::HashSet;

use base64::Engine;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// The GitHub repository releases come from when the build names none.
pub const DEFAULT_REPOSITORY: &str = "IAMichan/nook";
/// The panel and the receipt keep this many changes.
pub const CHANGE_LIMIT: usize = 60;
/// When a running Nook looks for an update, as on the Mac (docs/UPDATES.md, "Release builds"): 20 seconds after launch,
/// then every 4 minutes and after the computer wakes. Each request after the first sends the last `ETag`, so an
/// unchanged list is a `304` that does not count against GitHub's rate limit.
pub const FIRST_CHECK_SECONDS: u64 = 20;
pub const CHECK_INTERVAL_SECONDS: u64 = 4 * 60;

/// The update feed's file name on the latest release (`release.yml`, "Update the update feed").
pub const FEED_NAME: &str = "nook-releases.json";

// MARK: Versions

/// A release version as the tags write it: `v0.2.0`, `v0.2.0-beta.3`. Ordered like SemVer: a pre-release comes before
/// its release, and its dot-separated parts compare numerically when both are numbers.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ReleaseVersion {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    /// "beta.3" → ["beta", "3"]; empty for a regular release.
    pub prerelease: Vec<String>,
}

impl ReleaseVersion {
    pub fn parse(text: &str) -> Option<Self> {
        let mut rest = text.trim();
        rest = rest.strip_prefix(['v', 'V']).unwrap_or(rest);
        // Build metadata (+…) does not take part in the order.
        if let Some(plus) = rest.find('+') {
            rest = &rest[..plus];
        }
        let mut prerelease = Vec::new();
        if let Some(dash) = rest.find('-') {
            prerelease = rest[dash + 1..].split('.').map(str::to_string).collect();
            if prerelease.iter().any(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_alphanumeric())) {
                return None;
            }
            rest = &rest[..dash];
        }
        let numbers: Vec<&str> = rest.split('.').collect();
        if numbers.len() != 3 || numbers.iter().any(|n| n.is_empty() || !n.chars().all(|c| c.is_ascii_digit())) {
            return None;
        }
        Some(Self { major: numbers[0].parse().ok()?, minor: numbers[1].parse().ok()?, patch: numbers[2].parse().ok()?, prerelease })
    }

    pub fn is_prerelease(&self) -> bool {
        !self.prerelease.is_empty()
    }
}

impl std::fmt::Display for ReleaseVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)?;
        if !self.prerelease.is_empty() {
            write!(f, "-{}", self.prerelease.join("."))?;
        }
        Ok(())
    }
}

impl Ord for ReleaseVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch).cmp(&(other.major, other.minor, other.patch)).then_with(|| {
            // 1.0.0-beta.1 < 1.0.0
            match (self.prerelease.is_empty(), other.prerelease.is_empty()) {
                (true, true) => return Ordering::Equal,
                (true, false) => return Ordering::Greater,
                (false, true) => return Ordering::Less,
                _ => {}
            }
            for (left, right) in self.prerelease.iter().zip(&other.prerelease) {
                if left == right {
                    continue;
                }
                return match (left.parse::<u64>(), right.parse::<u64>()) {
                    (Ok(l), Ok(r)) => l.cmp(&r),
                    // Numeric parts come before alphanumeric ones.
                    (Ok(_), Err(_)) => Ordering::Less,
                    (Err(_), Ok(_)) => Ordering::Greater,
                    (Err(_), Err(_)) => left.cmp(right),
                };
            }
            self.prerelease.len().cmp(&other.prerelease.len())
        })
    }
}

impl PartialOrd for ReleaseVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

// MARK: Channel and build

/// Which releases a downloaded build follows: Stable takes regular releases only, Beta also the pre-releases.
/// Switching never offers a version older than the running one, because that build may already have migrated the data
/// past what an older one understands; a beta that moves to Stable keeps running until the first regular release after it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    Stable,
    Beta,
}

impl UpdateChannel {
    pub fn includes_prereleases(self) -> bool {
        self == UpdateChannel::Beta
    }
}

/// Which release file updates this copy: the same kind of file that installed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdatePlatform {
    /// `Nook-<version>-Windows-setup.exe` (NSIS; it replaces the installed app in place).
    Windows,
    /// `Nook-<version>-Linux.AppImage` (the running AppImage file is swapped).
    LinuxAppImage,
    /// `Nook-<version>-Windows.msi` (Windows Installer, per machine: Windows asks for administrator rights).
    WindowsMsi,
    /// `Nook-<version>-Linux.deb` (installed with apt or dpkg through pkexec, which asks for your password).
    LinuxDeb,
}

impl UpdatePlatform {
    /// The release workflow's file name for `version`; the signature sits next to it with `.sig` appended.
    pub fn installer_name(self, version: &ReleaseVersion) -> String {
        match self {
            UpdatePlatform::Windows => format!("Nook-{version}-Windows-setup.exe"),
            UpdatePlatform::LinuxAppImage => format!("Nook-{version}-Linux.AppImage"),
            UpdatePlatform::WindowsMsi => format!("Nook-{version}-Windows.msi"),
            UpdatePlatform::LinuxDeb => format!("Nook-{version}-Linux.deb"),
        }
    }

    pub fn signature_name(self, version: &ReleaseVersion) -> String {
        self.installer_name(version) + ".sig"
    }
}

/// What a downloaded build knows about itself, as the release workflow stamped it in at build time
/// (`NOOK_RELEASE_VERSION`, `NOOK_RELEASE_REPOSITORY`, `NOOK_UPDATE_PUBLIC_KEY`). None for a build that the release
/// workflow did not make.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseBuild {
    /// The full version with its pre-release part (0.2.0-beta.3): the installer's own version has no suffix.
    pub version: ReleaseVersion,
    /// "owner/name".
    pub repository: String,
    /// The Ed25519 public key (32 bytes). Without one Nook can say a newer release exists but never installs one it
    /// cannot check.
    pub public_key: Option<Vec<u8>>,
}

impl ReleaseBuild {
    pub fn from_stamps(version: Option<&str>, repository: Option<&str>, public_key: Option<&str>) -> Option<Self> {
        let version = ReleaseVersion::parse(filled(version)?)?;
        let repository = filled(repository).filter(|r| is_repository(r)).unwrap_or(DEFAULT_REPOSITORY).to_string();
        let public_key = filled(public_key).and_then(UpdateSignature::public_key);
        Some(Self { version, repository, public_key })
    }

    /// Betas follow betas: a beta build is offered newer betas and releases, a regular release only regular releases,
    /// until another channel is picked in Settings.
    pub fn default_channel(&self) -> UpdateChannel {
        if self.version.is_prerelease() {
            UpdateChannel::Beta
        } else {
            UpdateChannel::Stable
        }
    }

    /// GitHub's list of releases, newest first. The fallback when the feed is not there (a release from before it).
    pub fn releases_url(&self) -> String {
        format!("https://api.github.com/repos/{}/releases?per_page=20", self.repository)
    }

    /// The update feed: the same list as a file on the latest release (the release workflow refreshes it with every
    /// release, betas included). A static download, so it does not count against GitHub's API rate limit.
    pub fn feed_url(&self) -> String {
        format!("https://github.com/{}/releases/latest/download/{FEED_NAME}", self.repository)
    }
}

/// This build, from what the release workflow stamped in (`tauri.yml`); None for a build from a checkout or CI.
pub fn this_build() -> Option<ReleaseBuild> {
    ReleaseBuild::from_stamps(
        option_env!("NOOK_RELEASE_VERSION"),
        option_env!("NOOK_RELEASE_REPOSITORY"),
        option_env!("NOOK_UPDATE_PUBLIC_KEY"),
    )
}

fn filled(text: Option<&str>) -> Option<&str> {
    text.map(str::trim).filter(|t| !t.is_empty() && !t.contains("$("))
}

pub fn is_repository(text: &str) -> bool {
    let parts: Vec<&str> = text.split('/').collect();
    parts.len() == 2
        && parts.iter().all(|p| {
            !p.is_empty() && p.len() <= 100 && *p != "." && *p != ".." && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
        })
}

// MARK: GitHub releases

/// One release as GitHub's API describes it (only what the update needs).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct GitHubRelease {
    #[serde(rename = "tag_name")]
    pub tag: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub prerelease: bool,
    #[serde(rename = "html_url", default)]
    pub page: Option<String>,
    #[serde(rename = "published_at", default)]
    pub published_at: Option<String>,
    #[serde(default)]
    pub assets: Vec<ReleaseAsset>,
    /// The release notes (Markdown); the release workflow puts GitHub's list of merged pull requests in them.
    #[serde(default)]
    pub body: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseAsset {
    pub name: String,
    #[serde(rename = "browser_download_url")]
    pub url: String,
    pub size: u64,
}

impl GitHubRelease {
    /// The list `GET /repos/{owner}/{repo}/releases` returns; releases that do not parse are left out.
    pub fn list(json: &str) -> Vec<GitHubRelease> {
        let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(json) else { return Vec::new() };
        items.into_iter().filter_map(|item| serde_json::from_value(item).ok()).collect()
    }
}

/// A pull request a release brought, read from its notes (`IncomingChange` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IncomingChange {
    pub title: String,
    pub pull_request: u64,
    pub author: String,
    pub date: Option<DateTime<Utc>>,
}

/// A newer release this build can install: its installer and the signature of that installer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseCandidate {
    pub version: ReleaseVersion,
    pub title: String,
    pub page: Option<String>,
    pub installer: ReleaseAsset,
    pub signature: ReleaseAsset,
    /// The pull requests the releases after this build brought, newest first; at most `CHANGE_LIMIT`.
    pub changes: Vec<IncomingChange>,
    /// How many there are in all.
    pub change_count: usize,
}

/// What the check found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReleaseCheck {
    UpToDate,
    Available(ReleaseCandidate),
    /// A newer release exists but carries no signature (or this build has no key to check one): it is shown with a
    /// link to download it by hand, never installed.
    Unsigned {
        version: ReleaseVersion,
        page: Option<String>,
    },
}

/// The newest release after `build` on `channel` (the build's own when None), with the files the install needs. Only
/// versions above the running one count on any channel. An installer over 1 GB or a signature over 1 KB is not what the
/// workflow makes and is skipped.
pub fn check(releases: &[GitHubRelease], build: &ReleaseBuild, platform: UpdatePlatform, channel: Option<UpdateChannel>) -> ReleaseCheck {
    let prereleases = channel.unwrap_or_else(|| build.default_channel()).includes_prereleases();
    let mut newer: Vec<(ReleaseVersion, &GitHubRelease)> = releases
        .iter()
        .filter(|r| !r.draft)
        .filter_map(|r| ReleaseVersion::parse(&r.tag).map(|v| (v, r)))
        .filter(|(v, r)| *v > build.version && (prereleases || (!v.is_prerelease() && !r.prerelease)))
        .collect();
    newer.sort_by(|a, b| b.0.cmp(&a.0));
    let Some((version, release)) = newer.first().cloned() else { return ReleaseCheck::UpToDate };
    let find = |name: String, max: u64| release.assets.iter().find(|a| a.name == name && a.size > 0 && a.size < max).cloned();
    let installer = find(platform.installer_name(&version), 1_000_000_000);
    let signature = find(platform.signature_name(&version), 1_024);
    let (Some(installer), Some(signature)) = (installer, signature) else {
        return ReleaseCheck::Unsigned { version, page: release.page.clone() };
    };
    if build.public_key.is_none() || !is_github_download(&installer.url) || !is_github_download(&signature.url) {
        return ReleaseCheck::Unsigned { version, page: release.page.clone() };
    }
    let title = release.name.as_deref().map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).unwrap_or(format!("Nook {version}"));
    // Every release between this build and the newest one: skipping a release must not hide what it brought.
    let all = changes(newer.iter().map(|(_, r)| *r));
    ReleaseCheck::Available(ReleaseCandidate {
        version,
        title,
        page: release.page.clone(),
        installer,
        signature,
        change_count: all.len(),
        changes: all.into_iter().take(CHANGE_LIMIT).collect(),
    })
}

/// Downloads come from GitHub over HTTPS (the signature is what makes them trusted; this keeps the URL honest).
pub fn is_github_download(url: &str) -> bool {
    let Ok(url) = url::Url::parse(url) else { return false };
    let Some(host) = url.host_str().map(str::to_ascii_lowercase) else { return false };
    url.scheme() == "https" && (host == "github.com" || host.ends_with(".githubusercontent.com"))
}

// MARK: Signature

pub struct UpdateSignature;

impl UpdateSignature {
    pub const PUBLIC_KEY_LENGTH: usize = 32;
    pub const SIGNATURE_LENGTH: usize = 64;

    /// The public key as the build carries it: base64 of the 32 raw bytes.
    pub fn public_key(text: &str) -> Option<Vec<u8>> {
        let data = base64::engine::general_purpose::STANDARD.decode(text.trim()).ok()?;
        (data.len() == Self::PUBLIC_KEY_LENGTH).then_some(data)
    }

    /// The `.sig` file: base64 of the 64-byte signature, on one line (`scripts/sign-update.sh` writes it).
    pub fn decode(file: &[u8]) -> Option<Vec<u8>> {
        let text = std::str::from_utf8(file).ok()?.trim();
        let data = base64::engine::general_purpose::STANDARD.decode(text).ok()?;
        (data.len() == Self::SIGNATURE_LENGTH).then_some(data)
    }

    /// The downloaded installer is genuine: signed with the private key that belongs to the build's public key.
    pub fn verify(installer: &[u8], signature_file: &[u8], public_key: &[u8]) -> bool {
        if public_key.len() != Self::PUBLIC_KEY_LENGTH {
            return false;
        }
        let Some(signature) = Self::decode(signature_file) else { return false };
        ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, public_key).verify(installer, &signature).is_ok()
    }
}

// MARK: Release notes

/// The pull requests of `releases` (newest release first), newest first, each once.
pub fn changes<'a>(releases: impl IntoIterator<Item = &'a GitHubRelease>) -> Vec<IncomingChange> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for release in releases {
        let date = release.published_at.as_deref().and_then(|d| DateTime::parse_from_rfc3339(d).ok()).map(|d| d.with_timezone(&Utc));
        // GitHub lists them oldest first.
        for change in parse_notes(release.body.as_deref().unwrap_or(""), date).into_iter().rev() {
            if seen.insert(change.pull_request) {
                result.push(change);
            }
        }
    }
    result
}

/// GitHub's generated list, one line per pull request: `* Title by @author in https://github.com/owner/repo/pull/123`.
pub fn parse_notes(body: &str, date: Option<DateTime<Utc>>) -> Vec<IncomingChange> {
    body.lines()
        .filter_map(|line| {
            let text = line.trim();
            let text = text.strip_prefix("* ").or_else(|| text.strip_prefix("- "))?;
            let in_at = text.rfind(" in https://github.com/")?;
            let by_at = text[..in_at].rfind(" by @")?;
            let link = &text[in_at + " in https://github.com/".len()..];
            let pull_at = link.find("/pull/")?;
            let digits: String = link[pull_at + 6..].chars().take_while(char::is_ascii_digit).collect();
            let number: u64 = digits.parse().ok().filter(|n| *n > 0)?;
            let title = text[..by_at].trim();
            let author = text[by_at + 5..in_at].trim();
            if title.is_empty() || author.is_empty() || author.contains(' ') {
                return None;
            }
            Some(IncomingChange { title: title.to_string(), pull_request: number, author: author.to_string(), date })
        })
        .collect()
}

// MARK: Where this copy came from

/// How the running copy of Nook was installed, which decides how it replaces itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum InstallKind {
    /// Nook's own Windows setup (NSIS, per user): it leaves `uninstall.exe` next to `nook.exe`, and the next setup
    /// replaces the app in place without asking for administrator rights.
    WindowsSetup,
    /// The `.msi` (per machine, in Program Files): the next `.msi` upgrades it, after Windows asks for administrator
    /// rights.
    WindowsMsi,
    /// An AppImage; `path` is the file that runs (`$APPIMAGE`), which the update swaps.
    AppImage { path: String },
    /// The `.deb` (dpkg owns the executable): the next `.deb` is installed through pkexec, which asks for your password.
    Deb,
    /// Put there some other way (built by hand, another package format): Nook links to the release instead.
    Package,
    /// A build that updates in another way (macOS has `AppUpdater`; Android has no downloads yet).
    Unsupported,
}

impl InstallKind {
    /// Reads the copy that runs: `os` is `std::env::consts::OS`, `has_uninstaller` whether `uninstall.exe` sits next to
    /// the executable, `appimage` the `APPIMAGE` variable the AppImage runtime sets, `dpkg_owned` whether
    /// `dpkg-query -S` names a package for the executable.
    pub fn detect(os: &str, has_uninstaller: bool, appimage: Option<&str>, dpkg_owned: bool) -> Self {
        match os {
            "windows" if has_uninstaller => InstallKind::WindowsSetup,
            "windows" => InstallKind::WindowsMsi,
            "linux" => match appimage.map(str::trim).filter(|p| !p.is_empty()) {
                Some(path) => InstallKind::AppImage { path: path.to_string() },
                None if dpkg_owned => InstallKind::Deb,
                None => InstallKind::Package,
            },
            _ => InstallKind::Unsupported,
        }
    }

    /// Which release file updates this copy; None when Nook does not update it by itself.
    pub fn platform(&self) -> Option<UpdatePlatform> {
        match self {
            InstallKind::WindowsSetup => Some(UpdatePlatform::Windows),
            InstallKind::WindowsMsi => Some(UpdatePlatform::WindowsMsi),
            InstallKind::AppImage { .. } => Some(UpdatePlatform::LinuxAppImage),
            InstallKind::Deb => Some(UpdatePlatform::LinuxDeb),
            InstallKind::Package | InstallKind::Unsupported => None,
        }
    }
}

/// `msiexec` arguments for an `.msi` update (Tauri's WiX template): `/passive` shows progress without questions,
/// `/norestart` never restarts Windows, and `AUTOLAUNCHAPP=True` starts Nook again when it is done.
pub fn msi_args(path: &str) -> Vec<String> {
    vec!["/i".into(), path.into(), "/passive".into(), "/norestart".into(), "AUTOLAUNCHAPP=True".into()]
}

/// The command that installs a `.deb` update as root: apt when it is there (it also fetches new dependencies), else
/// dpkg. pkexec asks for your password in a system dialog.
pub fn deb_command(path: &str, has_apt: bool) -> Vec<String> {
    if has_apt {
        ["pkexec", "apt-get", "install", "-y", "--no-install-recommends", path].map(String::from).to_vec()
    } else {
        ["pkexec", "dpkg", "-i", path].map(String::from).to_vec()
    }
}

/// The arguments for Nook's Windows setup when it runs as an update (Tauri's NSIS template): `/P` passive, a progress
/// window without questions; `/UPDATE` keeps the shortcuts and skips the "already installed" page; `/R` starts Nook
/// again once the files are in place. The setup closes a Nook that still runs before it copies.
pub const WINDOWS_SETUP_ARGS: [&str; 3] = ["/P", "/UPDATE", "/R"];

/// The file name the downloaded installer is kept under while it runs; only letters, digits, dots and dashes, so a
/// release name can never point outside the updates folder.
pub fn download_name(name: &str) -> Option<&str> {
    let safe = !name.is_empty()
        && name.len() <= 120
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
        && !name.contains("..");
    safe.then_some(name)
}

// MARK: Policy

/// What an administrator allows, the same keys on every platform (docs/UPDATES.md, "Turning updates off"):
/// `DisableUpdates` stops checking and installing, `DisableBetaChannel` keeps Nook on Stable. The environment variable
/// `NOOK_DISABLE_UPDATES=1` turns updates off for one machine or one launch.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdatePolicy {
    pub disabled: bool,
    pub beta_disabled: bool,
    /// Where the restriction comes from, for Settings ("your administrator", "NOOK_DISABLE_UPDATES"); None when free.
    pub source: Option<PolicySource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PolicySource {
    /// The environment variable.
    Environment,
    /// A managed policy (registry, `/etc/nook/policy.json`, a configuration profile on the Mac).
    Administrator,
    /// A policy that is there but cannot be read: updates are off rather than doing what it may forbid.
    Unreadable,
}

/// The policy file on Linux.
pub const LINUX_POLICY_PATH: &str = "/etc/nook/policy.json";
/// The registry key on Windows (under HKEY_LOCAL_MACHINE, then HKEY_CURRENT_USER); DWORD values.
pub const WINDOWS_POLICY_KEY: &str = r"SOFTWARE\Policies\Nook";

impl UpdatePolicy {
    /// Combines the sources. `env` is `NOOK_DISABLE_UPDATES`; `managed` the managed values that were found
    /// (`DisableUpdates`, `DisableBetaChannel`), or `Err` when a policy exists but cannot be read.
    pub fn resolve(env: Option<&str>, managed: Result<Option<(bool, bool)>, ()>) -> Self {
        let env_off = env.map(str::trim).is_some_and(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"));
        match managed {
            Err(()) => UpdatePolicy { disabled: true, beta_disabled: true, source: Some(PolicySource::Unreadable) },
            Ok(Some((disabled, beta))) if disabled || beta => {
                UpdatePolicy { disabled: disabled || env_off, beta_disabled: beta, source: Some(PolicySource::Administrator) }
            }
            _ if env_off => UpdatePolicy { disabled: true, beta_disabled: false, source: Some(PolicySource::Environment) },
            _ => UpdatePolicy::default(),
        }
    }

    /// `/etc/nook/policy.json`: `{"disableUpdates": true, "disableBetaChannel": true}` (both optional). None when
    /// absent, `Err` when it is not that.
    // The caller only needs to know the file is broken (it then keeps updates off), not why.
    #[allow(clippy::result_unit_err)]
    pub fn parse_json(text: Option<&str>) -> Result<Option<(bool, bool)>, ()> {
        let Some(text) = text else { return Ok(None) };
        let value: serde_json::Value = serde_json::from_str(text).map_err(|_| ())?;
        let object = value.as_object().ok_or(())?;
        let flag = |key: &str| match object.get(key) {
            None => Ok(false),
            Some(serde_json::Value::Bool(b)) => Ok(*b),
            Some(_) => Err(()),
        };
        Ok(Some((flag("disableUpdates")?, flag("disableBetaChannel")?)))
    }

    /// One DWORD from `reg query <key> /v <name>` (`    DisableUpdates    REG_DWORD    0x1`); None when the value is not there.
    pub fn parse_reg_query(output: &str, name: &str) -> Option<bool> {
        output.lines().find_map(|line| {
            let parts: Vec<&str> = line.split_whitespace().collect();
            match parts.as_slice() {
                [n, "REG_DWORD", value] if n.eq_ignore_ascii_case(name) => {
                    u32::from_str_radix(value.trim_start_matches("0x"), 16).ok().map(|v| v != 0)
                }
                _ => None,
            }
        })
    }

    /// The channel a build may follow under this policy.
    pub fn channel(&self, wanted: UpdateChannel) -> UpdateChannel {
        if self.beta_disabled {
            UpdateChannel::Stable
        } else {
            wanted
        }
    }
}

// MARK: Steps and receipt

/// The steps of an install, shown one by one in the update panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdateStep {
    Download,
    Verify,
    Install,
    Restart,
}

impl UpdateStep {
    pub const SEQUENCE: [UpdateStep; 4] = [UpdateStep::Download, UpdateStep::Verify, UpdateStep::Install, UpdateStep::Restart];
}

/// What an install promised, written before Nook restarts into the new version, so the next launch can show what is
/// new and notice an install that did not take.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateReceipt {
    pub from: String,
    pub to: String,
    pub changes: Vec<IncomingChange>,
    pub installed_at: DateTime<Utc>,
}

impl UpdateReceipt {
    /// The version that should be running now but is not; None when the receipt is not about this build or is older
    /// than a day.
    pub fn not_applied(&self, running: &str, now: DateTime<Utc>) -> Option<&str> {
        (self.from == running && self.to != running && now - self.installed_at < chrono::Duration::hours(24)).then_some(self.to.as_str())
    }
}

pub mod tool_updates;
pub mod trial;

#[cfg(test)]
mod tests;
