//! Installs Google's Antigravity ACP server (`AntigravityInstaller` and `AntigravityRelease` on the Mac): the pinned
//! release for this computer, checked on size and SHA-256 before anything is unpacked, exactly the two expected files of
//! the expected sizes, a test start that must answer as Antigravity with Google sign-in, and only then made active.
//! Nothing is installed when a step fails. Google publishes the same release for Windows and Linux as for macOS.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::antigravity::{Paths, AUTH_METHOD, REMOVED_ENVIRONMENT};
use crate::i18n::{tr, trf};

pub const VERSION: &str = "1.3.0";
/// The name the server gives itself in `initialize` (`AntigravityAcp.agentName`).
pub const AGENT_NAME: &str = "antigravity-acp";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Member {
    pub name: &'static str,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Asset {
    pub platform: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    pub archive_bytes: u64,
    pub executable: Member,
    pub harness: Member,
}

const BASE: &str = "https://dl.google.com/agy-extensions/releases";

/// The pinned release for an operating system and architecture (`std::env::consts` names).
pub fn asset(os: &str, arch: &str) -> Option<Asset> {
    let a = |platform, url, sha256, archive_bytes, exe: (&'static str, u64), harness: (&'static str, u64)| Asset {
        platform,
        url,
        sha256,
        archive_bytes,
        executable: Member { name: exe.0, bytes: exe.1 },
        harness: Member { name: harness.0, bytes: harness.1 },
    };
    Some(match (os, arch) {
        ("macos", "aarch64") => a(
            "darwin-arm64",
            concat!("https://dl.google.com/agy-extensions/releases", "/macos/agy-acp-server-1.3.0-darwin-arm64.zip"),
            "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88",
            111_456_962,
            ("agy_acp_server.par", 278_535_456),
            ("localharness_external", 118_611_392),
        ),
        ("macos", "x86_64") => a(
            "darwin-x64",
            concat!("https://dl.google.com/agy-extensions/releases", "/macos/agy-acp-server-1.3.0-darwin-x86_64.zip"),
            "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646",
            117_245_544,
            ("agy_acp_server.par", 282_840_688),
            ("localharness_external", 124_175_392),
        ),
        ("windows", "x86_64") => a(
            "windows-x64",
            concat!("https://dl.google.com/agy-extensions/releases", "/windows/agy-acp-server-1.3.0-windows-x86_64.zip"),
            "65215e0688681fa3116e048a9eab27ef53af1bbd6f3da3f1c52bd4911d8b17f9",
            124_509_787,
            ("agy_acp_server.exe", 81_437_336),
            ("localharness_external.exe", 145_548_952),
        ),
        ("linux", "x86_64") => a(
            "linux-x64",
            concat!("https://dl.google.com/agy-extensions/releases", "/linux/agy-acp-server-1.3.0-linux-x86_64.zip"),
            "9fb60956af0a9d76220a4db91ca9ac88e2a2372ad68f985ab5fceace6b825b96",
            333_727_150,
            ("agy_acp_server.par", 926_533_965),
            ("localharness_external", 130_388_040),
        ),
        ("windows", "aarch64") => a(
            "windows-arm64",
            concat!("https://dl.google.com/agy-extensions/releases", "/windows/agy-acp-server-1.3.0-windows-arm64.zip"),
            "4a0f469720e9beb9438a979f543fdbfad5022ebe0992c052c590bd78b3144ca3",
            124_654_803,
            ("agy_acp_server.exe", 85_893_472),
            ("localharness_external.exe", 135_640_216),
        ),
        ("linux", "aarch64") => a(
            "linux-arm64",
            concat!("https://dl.google.com/agy-extensions/releases", "/linux/agy-acp-server-1.3.0-linux-arm64.zip"),
            "500b0bc0fb858e88f4df404d4cedf80bf9298c178291e39e383d6c50b111cbdf",
            321_690_363,
            ("agy_acp_server.par", 930_848_992),
            ("localharness_external", 123_224_968),
        ),
        _ => return None,
    })
}

/// The release for this computer; `None` where Google publishes none.
pub fn current() -> Option<Asset> {
    let _ = BASE;
    asset(std::env::consts::OS, std::env::consts::ARCH)
}

/// Where the releases of `asset` live: `<tools>/<platform>/versions/<sha256>`, with `active.json` beside `versions`.
fn versions(paths: &Paths, asset: &Asset) -> PathBuf {
    paths.tools().join(asset.platform).join("versions")
}

fn release(paths: &Paths, asset: &Asset) -> PathBuf {
    versions(paths, asset).join(asset.sha256)
}

fn active(paths: &Paths, asset: &Asset) -> PathBuf {
    paths.tools().join(asset.platform).join("active.json")
}

/// Nook installed an Antigravity server here once (whatever release), as `active.json` says.
pub fn was_installed(paths: &Paths) -> bool {
    current().is_some_and(|asset| active(paths, &asset).is_file())
}

/// The installed server and harness, when the active release is the pinned one and complete.
pub fn installed(paths: &Paths) -> Option<(PathBuf, PathBuf)> {
    let asset = current()?;
    let record: Value = serde_json::from_slice(&std::fs::read(active(paths, &asset)).ok()?).ok()?;
    if record["releaseId"].as_str() != Some(asset.sha256) {
        return None;
    }
    let folder = release(paths, &asset);
    let executable = folder.join(asset.executable.name);
    let harness = folder.join(asset.harness.name);
    (executable.is_file() && harness.is_file()).then_some((executable, harness))
}

/// Exactly the two pinned files, each of the pinned size.
pub fn verify(files: &[(String, u64)], asset: &Asset) -> bool {
    files.len() == 2
        && files.iter().any(|(n, b)| n == asset.executable.name && *b == asset.executable.bytes)
        && files.iter().any(|(n, b)| n == asset.harness.name && *b == asset.harness.bytes)
}

/// `initialize` answered as Antigravity with Google sign-in (`AntigravityAcp.looksInstalled`).
pub fn looks_installed(result: &Value) -> bool {
    result["agentInfo"]["name"].as_str() == Some(AGENT_NAME)
        && result["authMethods"].as_array().is_some_and(|m| m.iter().any(|x| x["id"].as_str() == Some(AUTH_METHOD)))
}

/// A step of an install, for the progress line.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Phase {
    Downloading(f64),
    Verifying,
    Unpacking,
    Checking,
}

/// Removes the server and its releases (the accounts' profiles stay).
pub fn uninstall(paths: &Paths) -> Result<(), String> {
    match std::fs::remove_dir_all(paths.tools()) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// Downloads, checks, unpacks, test-starts and activates the pinned release. `progress` hears each step.
pub async fn install(paths: &Paths, mut progress: impl FnMut(Phase) + Send) -> Result<(), String> {
    let asset = current().ok_or_else(|| {
        tr("Er is geen Antigravity-server voor deze computer.", "There is no Antigravity server for this computer.").to_string()
    })?;
    let failed = |e: &dyn std::fmt::Display| {
        trf("Antigravity installeren lukte niet: {error}", "Couldn't install Antigravity: {error}", &[("error", e)])
    };
    let versions = versions(paths, &asset);
    std::fs::create_dir_all(&versions).map_err(|e| failed(&e))?;
    let archive = versions.join(format!(".download-{}.zip", uuid::Uuid::new_v4()));
    let result = async {
        download(&asset, &archive, &mut progress).await?;
        progress(Phase::Verifying);
        let (bytes, digest) = sha256(&archive).map_err(|e| failed(&e))?;
        if bytes != asset.archive_bytes || digest != asset.sha256 {
            return Err(tr(
                "De download klopt niet (grootte of SHA-256). Er is niets geïnstalleerd.",
                "The download does not match (size or SHA-256). Nothing was installed.",
            )
            .to_string());
        }
        progress(Phase::Unpacking);
        let staging = versions.join(format!(".staging-{}", uuid::Uuid::new_v4()));
        let outcome = (|| {
            unpack(&archive, &staging, &asset)?;
            progress(Phase::Checking);
            smoke_test(&staging.join(asset.executable.name), &staging.join(asset.harness.name))?;
            let target = release(paths, &asset);
            let _ = std::fs::remove_dir_all(&target);
            std::fs::rename(&staging, &target).map_err(|e| failed(&e))?;
            let record = json!({"releaseId": asset.sha256, "version": VERSION});
            crate::paths::write_atomic(&active(paths, &asset), record.to_string().as_bytes()).map_err(|e| failed(&e))?;
            // The releases this one replaces: nothing runs from them any more.
            if let Ok(entries) = std::fs::read_dir(&versions) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if name != asset.sha256 && !name.starts_with('.') {
                        let _ = std::fs::remove_dir_all(entry.path());
                    }
                }
            }
            Ok(())
        })();
        let _ = std::fs::remove_dir_all(&staging);
        outcome
    }
    .await;
    let _ = std::fs::remove_file(&archive);
    result
}

async fn download(asset: &Asset, to: &Path, progress: &mut (impl FnMut(Phase) + Send)) -> Result<(), String> {
    let failed = |e: &dyn std::fmt::Display| trf("De download lukte niet: {error}", "The download failed: {error}", &[("error", e)]);
    progress(Phase::Downloading(0.0));
    let response = reqwest::Client::new().get(asset.url).send().await.map_err(|e| failed(&e))?;
    if !response.status().is_success() {
        return Err(failed(&response.status()));
    }
    let mut file = std::fs::File::create(to).map_err(|e| failed(&e))?;
    let mut stream = response.bytes_stream();
    let mut done: u64 = 0;
    let mut shown = 0.0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| failed(&e))?;
        file.write_all(&chunk).map_err(|e| failed(&e))?;
        done += chunk.len() as u64;
        // Too big is never what was pinned; stop reading instead of filling the disk.
        if done > asset.archive_bytes {
            return Err(failed(&"too large"));
        }
        let fraction = done as f64 / asset.archive_bytes as f64;
        if fraction - shown >= 0.01 {
            shown = fraction;
            progress(Phase::Downloading(fraction));
        }
    }
    file.flush().map_err(|e| failed(&e))
}

fn sha256(file: &Path) -> std::io::Result<(u64, String)> {
    let mut reader = std::fs::File::open(file)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    let mut bytes = 0u64;
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        hasher.update(&buffer[..n]);
    }
    Ok((bytes, hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()))
}

/// Only the two expected files, flat, of exactly the pinned sizes; made executable.
fn unpack(archive: &Path, into: &Path, asset: &Asset) -> Result<(), String> {
    let bad = || {
        tr(
            "Het archief bevat niet precies de verwachte bestanden. Er is niets geïnstalleerd.",
            "The archive does not hold exactly the expected files. Nothing was installed.",
        )
        .to_string()
    };
    let file = std::fs::File::open(archive).map_err(|_| bad())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| bad())?;
    let names: Vec<String> =
        (0..zip.len()).filter_map(|i| zip.by_index(i).ok().and_then(|f| f.name().ok().map(|n| n.to_string()))).collect();
    let expected = [asset.executable.name, asset.harness.name];
    if names.len() != 2 || !expected.iter().all(|e| names.iter().any(|n| n == e)) {
        return Err(bad());
    }
    std::fs::create_dir_all(into).map_err(|_| bad())?;
    crate::paths::restrict(into, 0o700);
    let mut files = vec![];
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|_| bad())?;
        let name = entry.name().map_err(|_| bad())?.to_string();
        if !expected.contains(&name.as_str()) || !entry.is_file() {
            return Err(bad());
        }
        let path = into.join(&name);
        let mut out = std::fs::File::create(&path).map_err(|_| bad())?;
        let written = std::io::copy(&mut entry, &mut out).map_err(|_| bad())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755));
        }
        files.push((name, written));
    }
    if verify(&files, asset) {
        Ok(())
    } else {
        Err(bad())
    }
}

/// A test start in a throwaway profile: `initialize` must answer as Antigravity, with Google sign-in, within 90 s.
fn smoke_test(executable: &Path, harness: &Path) -> Result<(), String> {
    let failed = || {
        tr(
            "De proefstart gaf niet het verwachte antwoord van Antigravity. Er is niets geïnstalleerd.",
            "The test start did not answer as Antigravity. Nothing was installed.",
        )
        .to_string()
    };
    let scratch = std::env::temp_dir().join(format!("nook-agy-check-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(scratch.join("antigravity-acp")).map_err(|_| failed())?;
    let _ = std::fs::write(scratch.join("antigravity-acp").join("settings.json"), super::antigravity::PROFILE_SETTINGS);
    let mut command = Command::new(executable);
    for name in REMOVED_ENVIRONMENT {
        command.env_remove(name);
    }
    command
        .current_dir(&scratch)
        .env("GEMINI_HOME", &scratch)
        .env("AGY_ACP_FORCE_FILE_STORAGE", "1")
        .env("ANTIGRAVITY_HARNESS_PATH", harness)
        .env("PYTHONUNBUFFERED", "1")
        .env("BROWSER", if cfg!(windows) { "cmd /c exit 0" } else { "true" })
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|_| failed())?;
    let request = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false},
        "clientInfo": {"name": "nook", "title": "Nook", "version": env!("CARGO_PKG_VERSION")}}});
    if let Some(mut stdin) = child.stdin.take() {
        let _ = writeln!(stdin, "{request}");
        // Kept open: the server ends when its input closes.
        std::mem::forget(stdin);
    }
    let stdout = child.stdout.take();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let Some(stdout) = stdout else { return };
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if v["id"] == json!(1) {
                    let _ = tx.send(v["result"].clone());
                    return;
                }
            }
        }
    });
    let answer = rx.recv_timeout(Duration::from_secs(90)).ok();
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&scratch);
    match answer {
        Some(result) if looks_installed(&result) => Ok(()),
        _ => Err(failed()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_a_release_for_every_desktop() {
        for (os, arch) in [
            ("macos", "aarch64"),
            ("macos", "x86_64"),
            ("windows", "x86_64"),
            ("windows", "aarch64"),
            ("linux", "x86_64"),
            ("linux", "aarch64"),
        ] {
            let a = asset(os, arch).unwrap();
            assert!(a.url.starts_with(BASE) && a.url.ends_with(".zip"), "{os} {arch}");
            assert_eq!(a.sha256.len(), 64);
        }
        assert_eq!(asset("windows", "x86_64").unwrap().executable.name, "agy_acp_server.exe");
        assert!(asset("freebsd", "x86_64").is_none());
    }

    #[test]
    fn checks_the_unpacked_files_and_the_answer() {
        let a = asset("linux", "x86_64").unwrap();
        let good = vec![(a.executable.name.to_string(), a.executable.bytes), (a.harness.name.to_string(), a.harness.bytes)];
        assert!(verify(&good, &a));
        let mut short = good.clone();
        short[1].1 -= 1;
        assert!(!verify(&short, &a));
        let mut extra = good.clone();
        extra.push(("evil".into(), 1));
        assert!(!verify(&extra, &a));
        assert!(looks_installed(&json!({"agentInfo": {"name": "antigravity-acp"}, "authMethods": [{"id": "oauth-personal"}]})));
        assert!(!looks_installed(&json!({"agentInfo": {"name": "other"}, "authMethods": [{"id": "oauth-personal"}]})));
    }

    /// With `NOOK_AGY_ZIP=<the Windows x64 archive>`: the real download checks and unpacks as pinned.
    #[test]
    fn unpacks_a_real_release_when_given() {
        let Ok(zip) = std::env::var("NOOK_AGY_ZIP") else { return };
        let a = asset("windows", "x86_64").unwrap();
        let (bytes, digest) = sha256(Path::new(&zip)).unwrap();
        assert_eq!((bytes, digest.as_str()), (a.archive_bytes, a.sha256));
        let into = std::env::temp_dir().join(format!("nook-agy-{}", uuid::Uuid::new_v4()));
        unpack(Path::new(&zip), &into, &a).unwrap();
        let _ = std::fs::remove_dir_all(into);
    }
}
