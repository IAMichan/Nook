//! Signing in to a mail account. Microsoft: the device-code flow (a code you type at microsoft.com/devicelogin, as Teams
//! does on the Mac), so Nook never sees your password. Google: the browser with PKCE, coming back to a one-time address
//! on 127.0.0.1 (RFC 8252). Only the refresh token is kept, in the keychain; access tokens live in memory.
//!
//! Nook's own app ids come with the build (`NOOK_MICROSOFT_CLIENT_ID`, `NOOK_GOOGLE_CLIENT_ID`,
//! `NOOK_GOOGLE_CLIENT_SECRET`); without them, Settings asks for your own (kept in the keychain).

use std::time::Duration;

use base64::Engine;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::Provider;
use crate::connectors::hub::Env;
use crate::connectors::{CResult, ConnectorError, ErrorKind, Http};

pub const MICROSOFT_AUTHORITY: &str = "https://login.microsoftonline.com/common/oauth2/v2.0";
pub const MICROSOFT_SCOPES: &str = "offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite";
pub const GOOGLE_AUTH: &str = "https://accounts.google.com/o/oauth2/v2/auth";
pub const GOOGLE_TOKEN: &str = "https://oauth2.googleapis.com/token";
pub const GOOGLE_SCOPES: &str =
    "openid email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/calendar.events";

pub const MICROSOFT_CLIENT_KEY: &str = "mail.microsoft.client";
pub const GOOGLE_CLIENT_KEY: &str = "mail.google.client";
pub const GOOGLE_SECRET_KEY: &str = "mail.google.secret";

/// The app Nook signs in to Microsoft as: yours from Settings, else Nook's own from the build.
pub fn microsoft_client(env: &Env) -> Option<String> {
    env.secret(MICROSOFT_CLIENT_KEY).or_else(|| option_env!("NOOK_MICROSOFT_CLIENT_ID").map(str::to_string)).filter(|c| !c.is_empty())
}

/// The app Nook signs in to Google as, and its (installed-app, not secret) client secret.
pub fn google_client(env: &Env) -> Option<(String, Option<String>)> {
    let own = env.secret(GOOGLE_CLIENT_KEY).map(|id| (id, env.secret(GOOGLE_SECRET_KEY)));
    own.or_else(|| {
        option_env!("NOOK_GOOGLE_CLIENT_ID").map(|id| (id.to_string(), option_env!("NOOK_GOOGLE_CLIENT_SECRET").map(str::to_string)))
    })
    .filter(|(id, _)| !id.is_empty())
}

/// What a token endpoint gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tokens {
    pub access: String,
    pub refresh: Option<String>,
    pub expires_in: i64,
}

pub fn tokens(v: &Value) -> Option<Tokens> {
    Some(Tokens {
        access: v["access_token"].as_str().filter(|t| !t.is_empty())?.to_string(),
        refresh: v["refresh_token"].as_str().map(str::to_string),
        expires_in: v["expires_in"].as_i64().unwrap_or(3600),
    })
}

async fn form(http: &Http, url: &str, fields: &[(&str, &str)]) -> CResult<(u16, Value)> {
    let response = http
        .client
        .post(url)
        .header("Accept", "application/json")
        .form(fields)
        .send()
        .await
        .map_err(|e| crate::connectors::network_error(e, "sign-in"))?;
    let status = response.status().as_u16();
    let body = response.json::<Value>().await.unwrap_or(Value::Null);
    Ok((status, body))
}

/// The code to type at Microsoft's page.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceCode {
    pub user_code: String,
    pub verification_uri: String,
    #[serde(skip)]
    pub device_code: String,
    pub interval: u64,
    pub expires_in: u64,
}

pub async fn start_device(http: &Http, authority: &str, client: &str) -> CResult<DeviceCode> {
    let (status, v) = form(http, &format!("{authority}/devicecode"), &[("client_id", client), ("scope", MICROSOFT_SCOPES)]).await?;
    let code = (status == 200).then_some(()).and_then(|_| {
        Some(DeviceCode {
            user_code: v["user_code"].as_str()?.into(),
            verification_uri: v["verification_uri"].as_str().unwrap_or("https://microsoft.com/devicelogin").into(),
            device_code: v["device_code"].as_str()?.into(),
            interval: v["interval"].as_u64().unwrap_or(5).max(1),
            expires_in: v["expires_in"].as_u64().unwrap_or(900),
        })
    });
    code.ok_or_else(|| ConnectorError::new(v["error_description"].as_str().unwrap_or("Microsoft did not start the sign-in.").to_string()))
}

/// Waits for you to finish at Microsoft's page: the tokens, or why not.
pub async fn finish_device(http: &Http, authority: &str, client: &str, code: &DeviceCode) -> CResult<Tokens> {
    let mut interval = code.interval;
    let deadline = std::time::Instant::now() + Duration::from_secs(code.expires_in);
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_secs(interval)).await;
        let (status, v) = form(
            http,
            &format!("{authority}/token"),
            &[("grant_type", "urn:ietf:params:oauth:grant-type:device_code"), ("client_id", client), ("device_code", &code.device_code)],
        )
        .await?;
        if status == 200 {
            return tokens(&v).ok_or_else(|| ConnectorError::new("Microsoft gave no token."));
        }
        match v["error"].as_str() {
            Some("authorization_pending") => {}
            Some("slow_down") => interval += 5,
            Some("authorization_declined") => return Err(ConnectorError::kind("You declined the sign-in.", ErrorKind::Auth)),
            _ => {
                return Err(ConnectorError::kind(
                    v["error_description"].as_str().unwrap_or("The sign-in failed.").lines().next().unwrap_or("").to_string(),
                    ErrorKind::Auth,
                ))
            }
        }
    }
    Err(ConnectorError::kind("The code expired before the sign-in finished.", ErrorKind::Auth))
}

/// A fresh access token from the kept refresh token. Microsoft may hand out a new refresh token with it.
pub async fn refresh(http: &Http, provider: Provider, env: &Env, refresh_token: &str) -> CResult<Tokens> {
    let ms = crate::connectors::api_base(MICROSOFT_AUTHORITY, "NOOK_MICROSOFT_AUTHORITY");
    let google = crate::connectors::api_base(GOOGLE_TOKEN, "NOOK_GOOGLE_TOKEN");
    refresh_at(http, provider, env, refresh_token, &ms, &google).await
}

/// Like [`refresh`], against explicit token endpoints (for tests without process-wide environment variables).
pub async fn refresh_at(
    http: &Http,
    provider: Provider,
    env: &Env,
    refresh_token: &str,
    microsoft_authority: &str,
    google_token: &str,
) -> CResult<Tokens> {
    let (status, v) = match provider {
        Provider::Microsoft => {
            let client = microsoft_client(env).ok_or_else(|| ConnectorError::not_set_up("Microsoft"))?;
            let url = format!("{microsoft_authority}/token");
            form(
                http,
                &url,
                &[
                    ("grant_type", "refresh_token"),
                    ("client_id", &client),
                    ("refresh_token", refresh_token),
                    ("scope", MICROSOFT_SCOPES),
                ],
            )
            .await?
        }
        Provider::Google => {
            let (client, secret) = google_client(env).ok_or_else(|| ConnectorError::not_set_up("Google"))?;
            let mut fields = vec![("grant_type", "refresh_token"), ("client_id", client.as_str()), ("refresh_token", refresh_token)];
            if let Some(s) = secret.as_deref() {
                fields.push(("client_secret", s));
            }
            form(http, google_token, &fields).await?
        }
    };
    if status == 200 {
        return tokens(&v).ok_or_else(|| ConnectorError::new("No token came back."));
    }
    Err(ConnectorError::kind(
        format!("{} wants you to sign in again (Settings › Mail and calendar).", provider.name()),
        ErrorKind::Auth,
    ))
}

/// PKCE: the verifier kept here and the challenge sent along.
pub fn pkce() -> (String, String) {
    let mut bytes = [0u8; 32];
    rand::TryRng::try_fill_bytes(&mut rand::rngs::SysRng, &mut bytes).expect("the system generator gives random bytes");
    let verifier = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}

pub fn google_url(client: &str, redirect: &str, challenge: &str, state: &str) -> String {
    crate::connectors::with_query(
        GOOGLE_AUTH,
        &[
            ("client_id", client.into()),
            ("redirect_uri", redirect.into()),
            ("response_type", "code".into()),
            ("scope", GOOGLE_SCOPES.into()),
            ("code_challenge", challenge.into()),
            ("code_challenge_method", "S256".into()),
            ("state", state.into()),
            ("access_type", "offline".into()),
            ("prompt", "consent".into()),
        ],
    )
}

/// The code from the browser's return to `http://127.0.0.1:<port>/callback?code=…&state=…`; only the answer with this
/// attempt's `state` counts.
pub fn callback_code(request_line: &str, state: &str) -> Result<String, String> {
    let path = request_line.split_whitespace().nth(1).unwrap_or("");
    let url = url::Url::parse(&format!("http://127.0.0.1{path}")).map_err(|_| "bad callback".to_string())?;
    if url.path() != "/callback" {
        return Err("not the callback".into());
    }
    let pairs: std::collections::HashMap<String, String> = url.query_pairs().into_owned().collect();
    if pairs.get("state").map(String::as_str) != Some(state) {
        return Err("state mismatch".into());
    }
    if let Some(error) = pairs.get("error") {
        return Err(error.clone());
    }
    pairs.get("code").cloned().ok_or_else(|| "no code".into())
}

/// Signs in to Google in the browser: `open` shows the page, the answer comes back to this computer. The tokens.
pub async fn google_sign_in(http: &Http, env: &Env, open: impl FnOnce(&str)) -> CResult<Tokens> {
    let token_url = crate::connectors::api_base(GOOGLE_TOKEN, "NOOK_GOOGLE_TOKEN");
    google_sign_in_at(http, env, &token_url, open).await
}

/// Like [`google_sign_in`], exchanging the authorization code against an explicit `token_url`.
pub async fn google_sign_in_at(http: &Http, env: &Env, token_url: &str, open: impl FnOnce(&str)) -> CResult<Tokens> {
    let (client, secret) = google_client(env).ok_or_else(|| ConnectorError::not_set_up("Google"))?;
    let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|e| ConnectorError::new(e.to_string()))?;
    let port = listener.local_addr().map_err(|e| ConnectorError::new(e.to_string()))?.port();
    let redirect = format!("http://127.0.0.1:{port}/callback");
    let (verifier, challenge) = pkce();
    let (state, _) = pkce();
    open(&google_url(&client, &redirect, &challenge, &state));
    let wait = async {
        loop {
            let Ok((mut socket, peer)) = listener.accept().await else { continue };
            if !peer.ip().is_loopback() {
                continue;
            }
            let mut buffer = vec![0u8; 8192];
            let n = socket.read(&mut buffer).await.unwrap_or(0);
            let text = String::from_utf8_lossy(&buffer[..n]).to_string();
            let result = callback_code(text.lines().next().unwrap_or(""), &state);
            if result == Err("not the callback".to_string()) {
                let _ = socket.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await;
                continue;
            }
            let page = if result.is_ok() { "Nook is signed in. You can close this tab." } else { "The sign-in did not finish. Try again in Nook." };
            let _ = socket
                .write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}", page.len()).as_bytes())
                .await;
            return result;
        }
    };
    let code = tokio::time::timeout(Duration::from_secs(300), wait)
        .await
        .map_err(|_| ConnectorError::kind("The sign-in took too long.", ErrorKind::Auth))?
        .map_err(|e| ConnectorError::kind(format!("The sign-in did not finish ({e})."), ErrorKind::Auth))?;
    let mut fields = vec![
        ("grant_type", "authorization_code"),
        ("client_id", client.as_str()),
        ("code", code.as_str()),
        ("redirect_uri", redirect.as_str()),
        ("code_verifier", verifier.as_str()),
    ];
    if let Some(s) = secret.as_deref() {
        fields.push(("client_secret", s));
    }
    let (status, v) = form(http, token_url, &fields).await?;
    if status != 200 {
        return Err(ConnectorError::kind("Google did not accept the sign-in.", ErrorKind::Auth));
    }
    tokens(&v).ok_or_else(|| ConnectorError::new("Google gave no token."))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::testserver::TestServer;

    #[test]
    fn only_this_attempts_answer_counts() {
        assert_eq!(callback_code("GET /callback?code=abc&state=s1 HTTP/1.1", "s1"), Ok("abc".into()));
        assert_eq!(callback_code("GET /callback?code=abc&state=other HTTP/1.1", "s1"), Err("state mismatch".into()));
        assert_eq!(callback_code("GET /favicon.ico HTTP/1.1", "s1"), Err("not the callback".into()));
        assert_eq!(callback_code("GET /callback?error=access_denied&state=s1 HTTP/1.1", "s1"), Err("access_denied".into()));
    }

    #[test]
    fn pkce_challenge_is_the_verifiers_hash() {
        let (verifier, challenge) = pkce();
        assert_eq!(challenge, base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())));
        let url = google_url("cid", "http://127.0.0.1:5/callback", &challenge, "st");
        assert!(url.contains("code_challenge_method=S256") && url.contains("access_type=offline") && url.contains("gmail.modify"));
    }

    #[tokio::test]
    async fn the_device_code_is_typed_then_the_token_comes() {
        let server = TestServer::start(vec![
            (
                "POST /devicecode",
                200,
                r#"{"user_code":"ABCD-EFGH","device_code":"dc","verification_uri":"https://microsoft.com/devicelogin","interval":1,"expires_in":30}"#.into(),
            ),
            ("POST /token", 200, r#"{"access_token":"at","refresh_token":"rt","expires_in":3599}"#.into()),
        ])
        .await;
        let authority = format!("http://127.0.0.1:{}", server.port);
        let http = Http::new();
        let code = start_device(&http, &authority, "cid").await.unwrap();
        assert_eq!(code.user_code, "ABCD-EFGH");
        let t = finish_device(&http, &authority, "cid", &code).await.unwrap();
        assert_eq!((t.access.as_str(), t.refresh.as_deref()), ("at", Some("rt")));
        let got = server.received.lock().unwrap().clone();
        assert!(got[0].body.contains("Mail.ReadWrite"));
        assert!(got[1].body.contains("device_code=dc"));
    }
}
