//! Pushmeldingen naar de iPhone via Apple (`APNsClient.swift`), zonder server van ons: deze computer ondertekent een
//! token (ES256) met jouw eigen APNs-sleutel (.p8) en stuurt de melding over HTTP/2 naar `api.push.apple.com`.
//! Apple ziet de tekst; daarom is die kort (zie [`super::push`]).

use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::pkcs8::DecodePrivateKey;
use serde_json::Value;

use super::models::base64url_encode;
use super::push::{self, Outcome};

/// De app-id van Nook Companion op de iPhone.
pub const TOPIC: &str = "nl.imdigital.nook.companion";

/// Alleen een privésleutel in PEM-vorm (de inhoud van het .p8-bestand); hij wordt nooit getoond of gelogd.
pub fn valid_pem(text: &str) -> bool {
    let text = text.trim();
    text.starts_with("-----BEGIN PRIVATE KEY-----")
        && text.ends_with("-----END PRIVATE KEY-----")
        && text.len() < 4_000
        && SigningKey::from_pkcs8_pem(text).is_ok()
}

/// De JWT die Apple wil: `header.claims.handtekening`, ES256 met de ruwe r‖s (64 bytes).
pub fn sign_jwt(pem: &str, key_id: &str, team_id: &str, issued_at: DateTime<Utc>) -> Option<String> {
    let input = push::jwt_signing_input(key_id, team_id, issued_at)?;
    let key = SigningKey::from_pkcs8_pem(pem.trim()).ok()?;
    let signature: Signature = key.sign(input.as_bytes());
    Some(format!("{input}.{}", base64url_encode(&signature.to_bytes())))
}

#[derive(Debug, Clone, PartialEq)]
pub struct ApnsResult {
    pub outcome: Outcome,
    pub status: u16,
    pub reason: Option<String>,
}

pub struct ApnsClient {
    http: reqwest::Client,
    cached: Mutex<Option<(String, DateTime<Utc>)>>,
}

impl Default for ApnsClient {
    fn default() -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().unwrap_or_default();
        Self { http, cached: Mutex::new(None) }
    }
}

impl ApnsClient {
    pub fn forget_token(&self) {
        *self.cached.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// Een ondertekend token, vijftig minuten hergebruikt (Apple weigert een nieuw vaker dan elke twintig).
    fn token(&self, pem: &str, key_id: &str, team_id: &str, now: DateTime<Utc>) -> Option<String> {
        let mut cached = self.cached.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((token, issued)) = &*cached {
            if (now - *issued).num_seconds() < push::JWT_LIFETIME_SECS {
                return Some(token.clone());
            }
        }
        let token = sign_jwt(pem, key_id, team_id, now)?;
        *cached = Some((token.clone(), now));
        Some(token)
    }

    pub async fn send(
        &self,
        pem: &str,
        key_id: &str,
        team_id: &str,
        payload: &Value,
        device_token: &str,
        production: bool,
        collapse_id: &str,
    ) -> ApnsResult {
        let not_configured = ApnsResult { outcome: Outcome::Configuration, status: 0, reason: Some("niet ingesteld".into()) };
        let Some(url) = push::endpoint(production, device_token) else { return not_configured };
        let Some(jwt) = self.token(pem, key_id, team_id, Utc::now()) else { return not_configured };
        let body = payload.to_string();
        if body.len() > 4_096 {
            return ApnsResult { outcome: Outcome::Configuration, status: 0, reason: Some("melding te groot".into()) };
        }
        let response = self
            .http
            .post(url)
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", TOPIC)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("apns-collapse-id", collapse_id)
            .header("content-type", "application/json")
            .body(body)
            .send()
            .await;
        match response {
            Ok(r) => {
                let status = r.status().as_u16();
                let reason = r.json::<Value>().await.ok().and_then(|v| v.get("reason").and_then(Value::as_str).map(String::from));
                // Een geweigerde sleutel blijft niet bewaard: de volgende poging ondertekent opnieuw.
                if status == 403 {
                    self.forget_token();
                }
                ApnsResult { outcome: push::outcome(status, reason.as_deref()), status, reason }
            }
            Err(e) => ApnsResult { outcome: Outcome::RetryLater, status: 0, reason: Some(e.to_string()) },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companion::models::base64url_decode;
    use p256::ecdsa::signature::Verifier;
    use p256::ecdsa::VerifyingKey;
    use p256::pkcs8::{EncodePrivateKey, LineEnding};

    fn pem() -> (String, VerifyingKey) {
        let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        (pem, *key.verifying_key())
    }

    #[test]
    fn signs_a_verifiable_jwt() {
        let (pem, public) = pem();
        assert!(valid_pem(&pem));
        let issued = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let jwt = sign_jwt(&pem, "ABC123DEFG", "35SMNHP9K7", issued).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let signature = Signature::from_slice(&base64url_decode(parts[2]).unwrap()).unwrap();
        public.verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature).unwrap();
        assert!(sign_jwt(&pem, "bad", "35SMNHP9K7", issued).is_none());
    }

    #[test]
    fn refuses_what_is_not_a_p8_key() {
        assert!(!valid_pem("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"));
        assert!(!valid_pem("hallo"));
    }

    #[test]
    fn reuses_the_token_for_fifty_minutes() {
        let (pem, _) = pem();
        let client = ApnsClient::default();
        let now = Utc::now();
        let a = client.token(&pem, "ABC123DEFG", "35SMNHP9K7", now).unwrap();
        let b = client.token(&pem, "ABC123DEFG", "35SMNHP9K7", now + chrono::Duration::minutes(49)).unwrap();
        assert_eq!(a, b);
        let c = client.token(&pem, "ABC123DEFG", "35SMNHP9K7", now + chrono::Duration::minutes(51)).unwrap();
        assert_ne!(a, c);
    }
}
