//! GOWA installed by Nook with one click (`WhatsAppGOWAInstaller`, `WAGOWARelease` on the Mac): GOWA's newest release
//! from its own GitHub page, the zip for this computer, SHA-256 checked against GOWA's own checksums, the binary put in
//! Nook's GOWA folder and started on 127.0.0.1 only. Nothing else is downloaded or run.
//!
//! Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use futures_util::StreamExt;
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::i18n::tr;

pub const LATEST_URL: &str = "https://api.github.com/repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest";

/// One file of a release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub size: u64,
    /// "sha256:<hex>" when GitHub gives it.
    pub digest: Option<String>,
}

/// `GET /releases/latest` → `{tag_name, assets: [{name, browser_download_url, size, digest?}]}`: the version without its
/// "v", and the files.
pub fn parse(data: &[u8]) -> Option<(String, Vec<Asset>)> {
    let v: Value = serde_json::from_slice(data).ok()?;
    let tag = v["tag_name"].as_str()?;
    let assets = v["assets"]
        .as_array()?
        .iter()
        .filter_map(|a| {
            Some(Asset {
                name: a["name"].as_str()?.to_string(),
                url: a["browser_download_url"].as_str()?.to_string(),
                size: a["size"].as_u64().unwrap_or(0),
                digest: a["digest"].as_str().map(str::to_string),
            })
        })
        .collect();
    Some((tag.strip_prefix('v').unwrap_or(tag).to_string(), assets))
}

/// GOWA's name for this computer's system and processor ("windows", "amd64"); `None` where GOWA publishes no build.
pub fn platform() -> Option<(&'static str, &'static str)> {
    let os = match std::env::consts::OS {
        "windows" => "windows",
        "linux" => "linux",
        "macos" => "darwin",
        _ => return None,
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        "x86" => "386",
        _ => return None,
    };
    Some((os, arch))
}

/// The zip for `os`/`arch` and the checksums file that names it (`checksums-macos.txt` for the Mac's, `checksums.txt`
/// for the others).
pub fn pick<'a>(assets: &'a [Asset], os: &str, arch: &str) -> Option<(&'a Asset, Option<&'a Asset>)> {
    let suffix = format!("_{os}_{arch}.zip");
    let zip = assets.iter().find(|a| a.name.starts_with("whatsapp_") && a.name.ends_with(&suffix))?;
    let sums = if os == "darwin" { "checksums-macos.txt" } else { "checksums.txt" };
    Some((zip, assets.iter().find(|a| a.name == sums)))
}

/// The binary's name inside the zip ("windows-amd64.exe", "linux-amd64", "darwin-arm64").
pub fn binary_name(os: &str, arch: &str) -> String {
    if os == "windows" {
        format!("{os}-{arch}.exe")
    } else {
        format!("{os}-{arch}")
    }
}

/// Where Nook keeps the GOWA it installed.
pub fn binary_path() -> PathBuf {
    let name = if cfg!(windows) { "gowa.exe" } else { "gowa" };
    crate::paths::support_directory().join("GOWA").join(name)
}

/// The SHA-256 (lowercase hex) of `asset` in a GoReleaser checksums file ("<hex>  <name>" per line), else GitHub's own
/// "sha256:<hex>" digest.
pub fn expected_sha256(asset: &Asset, checksums: Option<&str>) -> Option<String> {
    for line in checksums.unwrap_or("").lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() == 2 && parts[1] == asset.name && parts[0].len() == 64 {
            return Some(parts[0].to_lowercase());
        }
    }
    let digest = asset.digest.as_deref()?.strip_prefix("sha256:")?;
    (digest.len() == 64).then(|| digest.to_lowercase())
}

/// "9.2.2" comes before "9.3.0", by number ("9.10" after "9.9"); a leading "v" does not count.
pub fn is_older(version: &str, than: &str) -> bool {
    let numbers = |t: &str| -> Vec<u64> {
        t.strip_prefix('v')
            .unwrap_or(t)
            .split('.')
            .map(|p| p.chars().take_while(char::is_ascii_digit).collect::<String>().parse().unwrap_or(0))
            .collect()
    };
    let (a, b) = (numbers(version), numbers(than));
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x < y;
        }
    }
    false
}

/// Only GitHub serves the download (its assets redirect to githubusercontent.com).
pub fn allowed_host(host: Option<&str>) -> bool {
    let Some(h) = host.map(str::to_lowercase) else { return false };
    h == "github.com" || h == "api.github.com" || h.ends_with(".githubusercontent.com")
}

/// Where an install is, for the Settings row (`WhatsAppGOWAInstaller.Step`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "step")]
pub enum Step {
    Idle,
    Checking,
    Downloading { megabytes: u64 },
    Verifying,
    Installing,
    Done { version: String },
    Failed { message: String },
}

impl Step {
    pub fn busy(&self) -> bool {
        matches!(self, Self::Checking | Self::Downloading { .. } | Self::Verifying | Self::Installing)
    }
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(600))
        .user_agent("Nook")
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.url().scheme() == "https" && allowed_host(attempt.url().host_str()) && attempt.previous().len() < 5 {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
        .unwrap_or_default()
}

/// Downloads, checks and unpacks GOWA's newest release into [`binary_path`]. `installed`: the version Nook installed
/// before, for an update (`None` installs whatever is newest). Returns the version now in place, `None` when the
/// installed one is already the newest.
pub async fn install(installed: Option<&str>, progress: impl Fn(Step)) -> Result<Option<String>, String> {
    let no_build = || tr("Er is geen GOWA-versie voor deze computer gevonden.", "No GOWA build for this computer was found.").to_string();
    let download_failed =
        || tr("Downloaden van GOWA lukte niet. Probeer het later opnieuw.", "Downloading GOWA failed. Try again later.").to_string();
    progress(Step::Checking);
    let (os, arch) = platform().ok_or_else(no_build)?;
    let http = client();
    // 1. Which build: GOWA's latest release, the zip for this computer.
    let meta = http
        .get(LATEST_URL)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|_| download_failed())?;
    if !meta.status().is_success() {
        return Err(download_failed());
    }
    let body = meta.bytes().await.map_err(|_| download_failed())?;
    let (version, assets) = parse(&body).ok_or_else(no_build)?;
    let (zip, sums) = pick(&assets, os, arch).ok_or_else(no_build)?;
    if installed.is_some_and(|v| !is_older(v, &version)) {
        return Ok(None);
    }
    let checksums = match sums {
        Some(s) => match http.get(&s.url).send().await {
            Ok(r) if r.status().is_success() => r.text().await.ok(),
            _ => None,
        },
        None => None,
    };
    let expected = expected_sha256(zip, checksums.as_deref()).ok_or_else(|| {
        tr(
            "GOWA publiceerde geen controlesom voor deze versie; Nook installeert niets zonder.",
            "GOWA published no checksum for this version; Nook installs nothing without one.",
        )
        .to_string()
    })?;

    // 2. Download, never more than the release says the file is.
    progress(Step::Downloading { megabytes: (zip.size / 1_000_000).max(1) });
    let folder = binary_path().parent().map(Path::to_path_buf).unwrap_or_else(crate::paths::support_directory);
    std::fs::create_dir_all(&folder).map_err(|_| download_failed())?;
    crate::paths::restrict(&folder, 0o700);
    let archive = folder.join(format!("download-{}.zip", uuid::Uuid::new_v4()));
    let fetched = download(&http, zip, &archive).await;
    let result = async {
        fetched.map_err(|_| download_failed())?;
        // 3. Verify: exactly the file GOWA published.
        progress(Step::Verifying);
        let digest = sha256(&archive).map_err(|_| download_failed())?;
        if digest != expected {
            return Err(tr(
                "Het gedownloade bestand klopt niet met de controlesom van GOWA. Niets geïnstalleerd.",
                "The download does not match GOWA's checksum. Nothing was installed.",
            )
            .to_string());
        }
        // 4. Unpack the one binary and put it in place.
        progress(Step::Installing);
        unpack(&archive, &binary_name(os, arch), &binary_path())?;
        Ok(Some(version))
    }
    .await;
    let _ = std::fs::remove_file(&archive);
    result
}

async fn download(http: &reqwest::Client, asset: &Asset, to: &Path) -> Result<(), ()> {
    let response = http.get(&asset.url).send().await.map_err(|_| ())?;
    if !response.status().is_success() {
        return Err(());
    }
    let mut file = std::fs::File::create(to).map_err(|_| ())?;
    let mut stream = response.bytes_stream();
    let mut done = 0u64;
    let limit = if asset.size > 0 { asset.size } else { 200_000_000 };
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| ())?;
        done += chunk.len() as u64;
        if done > limit {
            return Err(());
        }
        file.write_all(&chunk).map_err(|_| ())?;
    }
    file.flush().map_err(|_| ())
}

fn sha256(file: &Path) -> std::io::Result<String> {
    let mut reader = std::fs::File::open(file)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Takes `binary` out of the zip (wherever it sits in it) and puts it at `dest`, runnable; an older one gives way.
pub fn unpack(archive: &Path, binary: &str, dest: &Path) -> Result<(), String> {
    let failed = || tr("Uitpakken van GOWA lukte niet.", "Unpacking GOWA failed.").to_string();
    let file = std::fs::File::open(archive).map_err(|_| failed())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| failed())?;
    let index = (0..zip.len())
        .find(|&i| {
            zip.by_index(i).ok().is_some_and(|f| {
                f.is_file() && f.name().ok().is_some_and(|n| n.rsplit('/').next() == Some(binary))
            })
        })
        .ok_or_else(|| tr("Er is geen GOWA-versie voor deze computer gevonden.", "No GOWA build for this computer was found.").to_string())?;
    let mut entry = zip.by_index(index).map_err(|_| failed())?;
    let temporary = dest.with_extension("new");
    {
        let mut out = std::fs::File::create(&temporary).map_err(|_| failed())?;
        std::io::copy(&mut entry, &mut out).map_err(|_| failed())?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o755));
    }
    let _ = std::fs::remove_file(dest);
    std::fs::rename(&temporary, dest).map_err(|_| failed())
}

#[cfg(test)]
mod tests {
    use super::*;

    const RELEASE: &str = r#"{"tag_name":"v9.10.0","assets":[
        {"name":"checksums-macos.txt","browser_download_url":"https://github.com/x/checksums-macos.txt","size":198},
        {"name":"checksums.txt","browser_download_url":"https://github.com/x/checksums.txt","size":588},
        {"name":"whatsapp_9.10.0_darwin_arm64.zip","browser_download_url":"https://github.com/x/d.zip","size":12339686,"digest":"sha256:d408114ac7f5af77d873bd032dbd49a92aa71cc5d1a8ffb3471d4190f0b307d4"},
        {"name":"whatsapp_9.10.0_windows_amd64.zip","browser_download_url":"https://github.com/x/w.zip","size":13456970},
        {"name":"whatsapp_9.10.0_linux_amd64.zip","browser_download_url":"https://github.com/x/l.zip","size":13209144}]}"#;

    #[test]
    fn the_release_names_the_zip_for_this_computer_and_its_checksums() {
        let (version, assets) = parse(RELEASE.as_bytes()).unwrap();
        assert_eq!(version, "9.10.0");
        let (zip, sums) = pick(&assets, "windows", "amd64").unwrap();
        assert_eq!(zip.name, "whatsapp_9.10.0_windows_amd64.zip");
        assert_eq!(sums.unwrap().name, "checksums.txt");
        let (zip, sums) = pick(&assets, "darwin", "arm64").unwrap();
        assert_eq!(zip.size, 12339686);
        assert_eq!(sums.unwrap().name, "checksums-macos.txt");
        assert!(pick(&assets, "windows", "arm64").is_none());
        assert_eq!(binary_name("windows", "amd64"), "windows-amd64.exe");
        assert_eq!(binary_name("linux", "amd64"), "linux-amd64");
    }

    #[test]
    fn the_checksum_comes_from_the_file_else_from_github() {
        let (_, assets) = parse(RELEASE.as_bytes()).unwrap();
        let windows = pick(&assets, "windows", "amd64").unwrap().0;
        let sums = "aa60a589e0e964518716d03c2c93c0ea6ce70d74d7c3b09c22c6ad324e27c203  whatsapp_9.10.0_windows_amd64.zip\n";
        assert_eq!(expected_sha256(windows, Some(sums)).unwrap(), "aa60a589e0e964518716d03c2c93c0ea6ce70d74d7c3b09c22c6ad324e27c203");
        // Nothing for it: nothing is installed.
        assert_eq!(expected_sha256(windows, None), None);
        let mac = pick(&assets, "darwin", "arm64").unwrap().0;
        assert_eq!(expected_sha256(mac, None).unwrap(), "d408114ac7f5af77d873bd032dbd49a92aa71cc5d1a8ffb3471d4190f0b307d4");
    }

    #[test]
    fn versions_compare_by_number_and_only_github_serves() {
        assert!(is_older("9.2.2", "9.3.0"));
        assert!(is_older("v9.9", "9.10"));
        assert!(!is_older("9.10.0", "9.10.0"));
        assert!(!is_older("10.0", "9.99"));
        assert!(allowed_host(Some("objects.githubusercontent.com")));
        assert!(allowed_host(Some("github.com")));
        assert!(!allowed_host(Some("github.com.evil.example")));
        assert!(!allowed_host(None));
    }

    #[test]
    fn only_the_binary_comes_out_of_the_zip() {
        let dir = std::env::temp_dir().join(format!("nook-gowa-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let archive = dir.join("w.zip");
        {
            let mut zip = zip::ZipWriter::new(std::fs::File::create(&archive).unwrap());
            let options = zip::write::SimpleFileOptions::default();
            zip.start_file("readme.md", options).unwrap();
            zip.write_all(b"read me").unwrap();
            zip.start_file("windows-amd64.exe", options).unwrap();
            zip.write_all(b"MZ binary").unwrap();
            zip.finish().unwrap();
        }
        let dest = dir.join("gowa.exe");
        std::fs::write(&dest, b"old").unwrap();
        unpack(&archive, "windows-amd64.exe", &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"MZ binary");
        assert!(unpack(&archive, "linux-amd64", &dir.join("other")).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
