//! The Rust counterpart of `ReleaseUpdateTests.swift`: versions, which release and which files, and the signature check.

use super::*;
use base64::engine::general_purpose::STANDARD;
use ring::signature::{Ed25519KeyPair, KeyPair};

const W: UpdatePlatform = UpdatePlatform::Windows;

fn key_pair() -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap()
}

fn key() -> Vec<u8> {
    key_pair().public_key().as_ref().to_vec()
}

fn asset(name: &str, size: u64) -> ReleaseAsset {
    ReleaseAsset { name: name.into(), url: format!("https://github.com/IAMichan/nook/releases/download/x/{name}"), size }
}

fn release(tag: &str, prerelease: Option<bool>, signed: bool, draft: bool) -> GitHubRelease {
    let version = ReleaseVersion::parse(tag).unwrap();
    let mut assets = vec![
        asset(&format!("Nook-{version}-macOS.zip"), 10),
        asset(&format!("Nook-{version}-macOS.zip.sig"), 89),
        asset(&format!("Nook-{version}-Windows-setup.exe"), 10),
        asset(&format!("Nook-{version}-Windows.msi"), 10),
        asset(&format!("Nook-{version}-Linux.AppImage"), 10),
    ];
    if signed {
        assets.push(asset(&format!("Nook-{version}-Windows-setup.exe.sig"), 89));
        assets.push(asset(&format!("Nook-{version}-Linux.AppImage.sig"), 89));
    }
    GitHubRelease {
        tag: tag.into(),
        name: Some(format!("Nook {version}")),
        draft,
        prerelease: prerelease.unwrap_or(version.is_prerelease()),
        page: Some(format!("https://github.com/IAMichan/nook/releases/tag/{tag}")),
        published_at: None,
        assets,
        body: None,
    }
}

fn r(tag: &str) -> GitHubRelease {
    release(tag, None, true, false)
}

fn v(text: &str) -> ReleaseVersion {
    ReleaseVersion::parse(text).unwrap()
}

fn build(version: &str, key: Option<Vec<u8>>) -> ReleaseBuild {
    ReleaseBuild { version: v(version), repository: DEFAULT_REPOSITORY.into(), public_key: key }
}

#[test]
fn versions_parse_and_order_like_semver() {
    assert_eq!(v("v0.2.0-beta.3").to_string(), "0.2.0-beta.3");
    assert!(v("1.2.3").prerelease.is_empty());
    assert_eq!(v("v1.2.3+build.5").to_string(), "1.2.3");
    for bad in ["", "v1", "1.2", "1.2.3.4", "v1.2.x", "1.2.3-", "1.2.3-beta..1", "1.2.3-bèta", "-1.2.3"] {
        assert!(ReleaseVersion::parse(bad).is_none(), "{bad}");
    }
    let ordered: Vec<ReleaseVersion> = [
        "0.1.0-alpha",
        "0.1.0-beta",
        "0.1.0-beta.2",
        "0.1.0-beta.10",
        "0.1.0-beta.10.1",
        "0.1.0-rc.1",
        "0.1.0",
        "0.1.1-beta.1",
        "0.1.1",
        "0.2.0",
        "1.0.0",
    ]
    .iter()
    .map(|t| v(t))
    .collect();
    let mut shuffled = ordered.clone();
    shuffled.reverse();
    shuffled.swap(2, 7);
    shuffled.sort();
    assert_eq!(shuffled, ordered);
    assert!(v("1.0.0-1") < v("1.0.0-beta"), "numbers before words");
    assert_eq!(v("v1.0.0"), v("1.0.0"));
}

#[test]
fn build_comes_from_its_stamps() {
    let encoded = STANDARD.encode(key());
    let b = ReleaseBuild::from_stamps(Some("0.3.0-beta.2"), Some("someone/fork"), Some(&encoded)).unwrap();
    assert_eq!(b.version, v("0.3.0-beta.2"));
    assert_eq!(b.repository, "someone/fork");
    assert_eq!(b.public_key, Some(key()));
    assert_eq!(b.default_channel(), UpdateChannel::Beta);
    assert_eq!(b.releases_url(), "https://api.github.com/repos/someone/fork/releases?per_page=20");

    assert!(ReleaseBuild::from_stamps(None, None, None).is_none(), "not made by the release workflow");
    let plain = ReleaseBuild::from_stamps(Some("1.0.0"), Some("../../evil"), Some("$(NOOK_UPDATE_PUBLIC_KEY)")).unwrap();
    assert!(plain.public_key.is_none(), "an unexpanded key is no key");
    assert_eq!(plain.repository, DEFAULT_REPOSITORY);
    assert!(ReleaseBuild::from_stamps(Some("1.0.0"), None, Some("c2hvcnQ=")).unwrap().public_key.is_none(), "too short");
}

#[test]
fn picks_the_newest_release_on_the_builds_channel() {
    let releases = [r("v0.3.0-beta.1"), r("v0.2.1"), r("v0.2.0"), release("v0.4.0", None, true, true)];
    let ReleaseCheck::Available(candidate) = check(&releases, &build("0.2.0-beta.4", Some(key())), W, None) else { panic!() };
    assert_eq!(candidate.version, v("0.3.0-beta.1"), "a beta build follows betas; drafts never count");
    assert_eq!(candidate.installer.name, "Nook-0.3.0-beta.1-Windows-setup.exe");
    assert_eq!(candidate.signature.name, "Nook-0.3.0-beta.1-Windows-setup.exe.sig");
    assert_eq!(candidate.title, "Nook 0.3.0-beta.1");

    let ReleaseCheck::Available(next) = check(&releases, &build("0.2.0", Some(key())), W, None) else { panic!() };
    assert_eq!(next.version, v("0.2.1"), "a regular release is offered regular releases only");

    let newest = build("0.3.0", Some(key()));
    assert_eq!(check(&releases, &newest, W, None), ReleaseCheck::UpToDate);
    assert_eq!(check(&[], &newest, W, None), ReleaseCheck::UpToDate);
    // A release marked pre-release on GitHub stays off the stable channel even with a plain tag.
    assert_eq!(check(&[release("v0.2.5", Some(true), true, false)], &build("0.2.0", Some(key())), W, None), ReleaseCheck::UpToDate);
}

#[test]
fn each_platform_takes_its_own_installer() {
    let ReleaseCheck::Available(linux) = check(&[r("v0.2.1")], &build("0.2.0", Some(key())), UpdatePlatform::LinuxAppImage, None) else {
        panic!()
    };
    assert_eq!(linux.installer.name, "Nook-0.2.1-Linux.AppImage");
    assert_eq!(linux.signature.name, "Nook-0.2.1-Linux.AppImage.sig");
}

#[test]
fn a_chosen_channel_overrides_the_builds_but_never_goes_back() {
    let releases = [r("v0.3.0-beta.3"), r("v0.2.1"), r("v0.2.0")];
    let stable = build("0.2.0", Some(key()));
    assert_eq!(stable.default_channel(), UpdateChannel::Stable);
    let ReleaseCheck::Available(beta) = check(&releases, &stable, W, Some(UpdateChannel::Beta)) else { panic!() };
    assert_eq!(beta.version, v("0.3.0-beta.3"), "a regular release that opts into Beta gets betas");

    let on_beta = build("0.3.0-beta.2", Some(key()));
    assert_eq!(on_beta.default_channel(), UpdateChannel::Beta);
    assert_eq!(check(&releases, &on_beta, W, Some(UpdateChannel::Stable)), ReleaseCheck::UpToDate, "never the older 0.2.1");
    let mut more = releases.to_vec();
    more.push(r("v0.3.0"));
    let ReleaseCheck::Available(next) = check(&more, &on_beta, W, Some(UpdateChannel::Stable)) else { panic!() };
    assert_eq!(next.version, v("0.3.0"), "it takes the first regular release after it");
}

#[test]
fn never_offers_what_cannot_be_checked() {
    let b = build("0.2.0", Some(key()));
    let unsigned = release("v0.2.1", None, false, false);
    assert_eq!(
        check(std::slice::from_ref(&unsigned), &b, W, None),
        ReleaseCheck::Unsigned { version: v("0.2.1"), page: unsigned.page.clone() }
    );
    assert!(matches!(check(&[r("v0.2.1")], &build("0.2.0", None), W, None), ReleaseCheck::Unsigned { .. }), "no key, no install");

    let elsewhere = GitHubRelease {
        assets: vec![
            ReleaseAsset { name: "Nook-0.2.1-Windows-setup.exe".into(), url: "http://example.com/Nook.exe".into(), size: 10 },
            asset("Nook-0.2.1-Windows-setup.exe.sig", 89),
        ],
        ..r("v0.2.1")
    };
    assert!(matches!(check(&[elsewhere], &b, W, None), ReleaseCheck::Unsigned { .. }), "not from GitHub over https");
    assert!(is_github_download("https://objects.githubusercontent.com/a"));
    assert!(!is_github_download("https://github.com.evil.example/a"));
    assert!(!is_github_download("not a url"));
}

#[test]
fn reads_githubs_release_list() {
    let json = r#"[{"tag_name": "v0.2.1", "name": "Nook 0.2.1", "draft": false, "prerelease": false,
      "html_url": "https://github.com/IAMichan/nook/releases/tag/v0.2.1", "published_at": "2026-10-01T10:00:00Z",
      "assets": [{"name": "Nook-0.2.1-Windows-setup.exe", "size": 1234,
                  "browser_download_url": "https://github.com/IAMichan/nook/releases/download/v0.2.1/Nook-0.2.1-Windows-setup.exe"}]},
     {"tag_name": 5}]"#;
    let releases = GitHubRelease::list(json);
    assert_eq!(releases.len(), 1, "a release that does not parse is skipped, not fatal");
    assert_eq!(releases[0].assets[0].size, 1234);
    assert!(GitHubRelease::list(r#"{"message": "rate limited"}"#).is_empty());
}

#[test]
fn signature_file_and_key_checks() {
    let installer = b"setup.exe bytes";
    let signature = key_pair().sign(installer);
    let file = format!("{}\n", STANDARD.encode(signature.as_ref()));
    assert_eq!(UpdateSignature::decode(file.as_bytes()), Some(signature.as_ref().to_vec()));
    assert!(UpdateSignature::decode(b"not base64").is_none());
    assert!(UpdateSignature::decode(STANDARD.encode([1u8; 63]).as_bytes()).is_none());

    assert!(UpdateSignature::verify(installer, file.as_bytes(), &key()));
    assert!(!UpdateSignature::verify(b"another file", file.as_bytes(), &key()), "a changed installer");
    assert!(!UpdateSignature::verify(installer, b"", &key()));
    assert!(!UpdateSignature::verify(installer, file.as_bytes(), &[1]));
    let other = Ed25519KeyPair::from_seed_unchecked(&[8u8; 32]).unwrap();
    assert!(!UpdateSignature::verify(installer, file.as_bytes(), other.public_key().as_ref()), "another key");
}

/// RFC 8032, test 1: a standard Ed25519 signature, as `scripts/sign-update.swift` and `scripts/sign-update.sh` make.
#[test]
fn ed25519_accepts_the_rfc_vector() {
    fn hex(text: &str) -> Vec<u8> {
        (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
    }
    let public_key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    let signature = STANDARD.encode(hex(
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ));
    assert!(UpdateSignature::verify(b"", signature.as_bytes(), &public_key));
    assert!(!UpdateSignature::verify(&[0], signature.as_bytes(), &public_key));
}

#[test]
fn steps_and_receipt() {
    assert_eq!(UpdateStep::SEQUENCE, [UpdateStep::Download, UpdateStep::Verify, UpdateStep::Install, UpdateStep::Restart]);
    let now = Utc::now();
    let receipt = UpdateReceipt { from: "0.2.0-beta.1".into(), to: "0.2.0-beta.2".into(), changes: vec![], installed_at: now };
    assert_eq!(receipt.not_applied("0.2.0-beta.1", now), Some("0.2.0-beta.2"));
    assert_eq!(receipt.not_applied("0.2.0-beta.2", now), None, "it took");
    assert_eq!(receipt.not_applied("0.2.0-beta.1", now + chrono::Duration::days(2)), None, "too old");
}

#[test]
fn reads_pull_requests_from_release_notes() {
    let body = "## What's new\n### What's Changed\n\
        * Add force restart for failed app updates by @IAMichan in https://github.com/IAMichan/Nook/pull/689\n\
        * Distinguish checks running from checks failing by @someone-else in https://github.com/IAMichan/Nook/pull/690\n\
        * Not a pull request line\n\
        **Full Changelog**: https://github.com/IAMichan/Nook/compare/v0.1.0-beta.1...v0.1.0-beta.2";
    let changes = parse_notes(body, None);
    assert_eq!(changes.iter().map(|c| c.pull_request).collect::<Vec<_>>(), [689, 690]);
    assert_eq!(changes[0].title, "Add force restart for failed app updates");
    assert_eq!(changes[1].author, "someone-else");
}

#[test]
fn candidate_lists_what_every_newer_release_brought() {
    fn notes(numbers: &[u64]) -> Option<String> {
        Some(
            numbers
                .iter()
                .map(|n| format!("* Change {n} by @a in https://github.com/IAMichan/Nook/pull/{n}"))
                .collect::<Vec<_>>()
                .join("\n"),
        )
    }
    let older = GitHubRelease { body: notes(&[1, 2]), ..r("v0.2.0-beta.2") };
    let newer = GitHubRelease { body: notes(&[3, 2]), ..r("v0.2.0-beta.3") };
    let current = GitHubRelease { body: notes(&[0]), assets: vec![], ..r("v0.2.0-beta.1") };
    let ReleaseCheck::Available(candidate) = check(&[newer, older, current], &build("0.2.0-beta.1", Some(key())), W, None) else {
        panic!()
    };
    assert_eq!(
        candidate.changes.iter().map(|c| c.pull_request).collect::<Vec<_>>(),
        [2, 3, 1],
        "newest release first, each pull request once, not this build's"
    );
    assert_eq!(candidate.change_count, 3);
}

/// What `scripts/sign-update.sh` (OpenSSL) wrote for "Nook update" with the test key: the release workflow's `.sig` for
/// Windows and Linux files is the format this build checks.
#[test]
fn reads_what_the_release_script_signs() {
    let file = b"uNhHH6qWYqaarzkPRBWggcJOBVnzi8h4TRe5f589zBd01sjg2t7VJ73wZUDkdbM1TMYGac0EXscAAp2qR/i9DQ==\n";
    assert!(UpdateSignature::verify(b"Nook update", file, &key()));
    assert_eq!(STANDARD.encode(key_pair().sign(b"Nook update")), std::str::from_utf8(file).unwrap().trim(), "Ed25519 is deterministic");
}

#[test]
fn knows_which_copies_update_themselves() {
    assert_eq!(InstallKind::detect("windows", true, None, false), InstallKind::WindowsSetup);
    assert_eq!(InstallKind::detect("windows", false, None, false), InstallKind::WindowsMsi);
    assert_eq!(
        InstallKind::detect("linux", false, Some("/home/a/Nook.AppImage"), false),
        InstallKind::AppImage { path: "/home/a/Nook.AppImage".into() }
    );
    assert_eq!(InstallKind::detect("linux", false, Some("  "), true), InstallKind::Deb);
    assert_eq!(InstallKind::detect("linux", false, None, true), InstallKind::Deb);
    assert_eq!(InstallKind::detect("linux", false, None, false), InstallKind::Package);
    assert_eq!(InstallKind::detect("android", false, None, false), InstallKind::Unsupported);
    assert_eq!(InstallKind::WindowsSetup.platform(), Some(UpdatePlatform::Windows));
    assert_eq!(InstallKind::WindowsMsi.platform(), Some(UpdatePlatform::WindowsMsi));
    assert_eq!(InstallKind::Deb.platform(), Some(UpdatePlatform::LinuxDeb));
    assert_eq!(InstallKind::detect("linux", false, Some("/x"), false).platform(), Some(UpdatePlatform::LinuxAppImage));
    assert_eq!(InstallKind::Package.platform(), None);
}

#[test]
fn packages_take_their_own_signed_file() {
    let build =
        ReleaseBuild { version: ReleaseVersion::parse("0.1.0").unwrap(), repository: DEFAULT_REPOSITORY.into(), public_key: Some(key()) };
    let mut next = release("v0.2.0", None, true, false);
    for check in [UpdatePlatform::WindowsMsi, UpdatePlatform::LinuxDeb] {
        assert!(matches!(super::check(&[next.clone()], &build, check, None), ReleaseCheck::Unsigned { .. }), "no .sig yet");
    }
    next.assets.push(asset("Nook-0.2.0-Windows.msi.sig", 89));
    next.assets.push(asset("Nook-0.2.0-Linux.deb", 10));
    next.assets.push(asset("Nook-0.2.0-Linux.deb.sig", 89));
    let ReleaseCheck::Available(msi) = super::check(&[next.clone()], &build, UpdatePlatform::WindowsMsi, None) else { panic!("msi") };
    assert_eq!(msi.installer.name, "Nook-0.2.0-Windows.msi");
    let ReleaseCheck::Available(deb) = super::check(&[next], &build, UpdatePlatform::LinuxDeb, None) else { panic!("deb") };
    assert_eq!(deb.signature.name, "Nook-0.2.0-Linux.deb.sig");
}

#[test]
fn packages_install_quietly_and_start_nook_again() {
    assert_eq!(msi_args("C:\\u\\n.msi"), ["/i", "C:\\u\\n.msi", "/passive", "/norestart", "AUTOLAUNCHAPP=True"]);
    assert_eq!(deb_command("/h/n.deb", true)[..3], ["pkexec", "apt-get", "install"]);
    assert_eq!(deb_command("/h/n.deb", false), ["pkexec", "dpkg", "-i", "/h/n.deb"]);
}

#[test]
fn setup_runs_as_a_quiet_update_that_restarts_nook() {
    assert!(WINDOWS_SETUP_ARGS.contains(&"/UPDATE"));
    assert!(WINDOWS_SETUP_ARGS.contains(&"/R"));
    assert!(!WINDOWS_SETUP_ARGS.contains(&"/S"), "passive shows progress, silent would show nothing for a minute");
}

#[test]
fn download_names_stay_in_the_updates_folder() {
    assert_eq!(download_name("Nook-0.2.0-beta.1-Windows-setup.exe"), Some("Nook-0.2.0-beta.1-Windows-setup.exe"));
    assert_eq!(download_name("../nook.exe"), None);
    assert_eq!(download_name("a/b.exe"), None);
    assert_eq!(download_name("a\\b.exe"), None);
    assert_eq!(download_name(".hidden"), None);
    assert_eq!(download_name(""), None);
}

#[test]
fn an_administrator_or_the_environment_can_turn_updates_off() {
    assert_eq!(UpdatePolicy::resolve(None, Ok(None)), UpdatePolicy::default());
    assert_eq!(UpdatePolicy::resolve(Some("0"), Ok(None)), UpdatePolicy::default());
    let env = UpdatePolicy::resolve(Some("1"), Ok(None));
    assert!(env.disabled && env.source == Some(PolicySource::Environment));
    let beta = UpdatePolicy::resolve(None, Ok(Some((false, true))));
    assert!(!beta.disabled && beta.beta_disabled && beta.source == Some(PolicySource::Administrator));
    assert_eq!(beta.channel(UpdateChannel::Beta), UpdateChannel::Stable);
    assert!(UpdatePolicy::resolve(None, Ok(Some((true, false)))).disabled);
    // Fails closed: a policy that is there but unreadable turns updates off.
    let broken = UpdatePolicy::resolve(None, Err(()));
    assert!(broken.disabled && broken.source == Some(PolicySource::Unreadable));
}

#[test]
fn reads_the_linux_policy_file() {
    assert_eq!(UpdatePolicy::parse_json(None), Ok(None));
    assert_eq!(UpdatePolicy::parse_json(Some(r#"{"disableUpdates": true}"#)), Ok(Some((true, false))));
    assert_eq!(UpdatePolicy::parse_json(Some(r#"{"disableBetaChannel": true}"#)), Ok(Some((false, true))));
    assert_eq!(UpdatePolicy::parse_json(Some(r#"{"disableUpdates": "yes"}"#)), Err(()));
    assert_eq!(UpdatePolicy::parse_json(Some("not json")), Err(()));
}

#[test]
fn the_feed_is_a_file_on_the_latest_release() {
    let build = ReleaseBuild { version: ReleaseVersion::parse("0.1.0").unwrap(), repository: "IAMichan/nook".into(), public_key: None };
    assert_eq!(build.feed_url(), "https://github.com/IAMichan/nook/releases/latest/download/nook-releases.json");
    // The feed has GitHub's own shape, so the same parser reads it.
    let feed = r#"[{"tag_name":"v0.2.0","name":"Nook 0.2.0","draft":false,"prerelease":false,"html_url":null,"published_at":null,"body":"","assets":[{"name":"a","size":1,"browser_download_url":"https://github.com/x"}]}]"#;
    assert_eq!(GitHubRelease::list(feed).len(), 1);
}

#[test]
fn reads_the_windows_policy_from_reg_query() {
    let out = "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Nook\r\n    DisableUpdates    REG_DWORD    0x1\r\n";
    assert_eq!(UpdatePolicy::parse_reg_query(out, "DisableUpdates"), Some(true));
    assert_eq!(UpdatePolicy::parse_reg_query("    DisableBetaChannel    REG_DWORD    0x0", "DisableBetaChannel"), Some(false));
    assert_eq!(UpdatePolicy::parse_reg_query(out, "DisableBetaChannel"), None);
    assert_eq!(UpdatePolicy::parse_reg_query("    DisableUpdates    REG_SZ    1", "DisableUpdates"), None);
}
