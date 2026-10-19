//! Verzegeling van companion-berichten (`CompanionSeal.swift`): ChaCha20-Poly1305 met een sleutel die met
//! HKDF-SHA256 uit de koppelsleutel komt. Toestel-id en richting zitten in de geauthenticeerde data, zodat een
//! aanvraag niet als antwoord kan worden teruggespeeld of andersom. Een envelop is
//! `{"d": "<toestel-id>", "s": "<base64 van nonce + versleutelde tekst + tag>"}`, net als `ChaChaPoly.SealedBox.combined`.

use base64::Engine;
use chacha20poly1305::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Request,
    Response,
}

impl Direction {
    fn raw(self) -> &'static str {
        match self {
            Direction::Request => "q",
            Direction::Response => "r",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SealError {
    Malformed,
    Authentication,
}

#[derive(Serialize, Deserialize)]
struct Envelope {
    d: String,
    s: String,
}

fn cipher(pairing_key: &[u8]) -> ChaCha20Poly1305 {
    let mut derived = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"nook-companion"), pairing_key).expand(b"v1", &mut derived).expect("32 bytes is een geldige HKDF-lengte");
    ChaCha20Poly1305::new(Key::from_slice(&derived))
}

fn aad(device_id: &str, direction: Direction) -> Vec<u8> {
    format!("{device_id}|{}", direction.raw()).into_bytes()
}

pub fn seal(plaintext: &[u8], pairing_key: &[u8], device_id: &str, direction: Direction) -> Vec<u8> {
    let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
    seal_with_nonce(plaintext, pairing_key, device_id, direction, nonce.into())
}

/// Met een vaste nonce; alleen voor testvectoren. Een nonce mag nooit twee keer met dezelfde sleutel.
pub fn seal_with_nonce(plaintext: &[u8], pairing_key: &[u8], device_id: &str, direction: Direction, nonce: [u8; 12]) -> Vec<u8> {
    let aad = aad(device_id, direction);
    let sealed = cipher(pairing_key)
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext, aad: &aad })
        .expect("versleutelen in het geheugen faalt niet");
    let mut combined = nonce.to_vec();
    combined.extend(sealed);
    let envelope = Envelope { d: device_id.into(), s: base64::engine::general_purpose::STANDARD.encode(combined) };
    serde_json::to_vec(&envelope).expect("JSON van twee tekenreeksen")
}

/// Het toestel-id dat een envelop noemt, om de sleutel te kiezen. Niet te vertrouwen tot `open` slaagt.
pub fn claimed_device(envelope: &[u8]) -> Option<String> {
    serde_json::from_slice::<Envelope>(envelope).ok().map(|e| e.d)
}

pub fn open(envelope: &[u8], pairing_key: &[u8], direction: Direction) -> Result<Vec<u8>, SealError> {
    let parsed: Envelope = serde_json::from_slice(envelope).map_err(|_| SealError::Malformed)?;
    let combined = base64::engine::general_purpose::STANDARD.decode(parsed.s.as_bytes()).map_err(|_| SealError::Malformed)?;
    if combined.len() <= 28 {
        return Err(SealError::Malformed);
    }
    let (nonce, sealed) = combined.split_at(12);
    let aad = aad(&parsed.d, direction);
    cipher(pairing_key).decrypt(Nonce::from_slice(nonce), Payload { msg: sealed, aad: &aad }).map_err(|_| SealError::Authentication)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companion::models::PairedDevice;

    fn key() -> Vec<u8> {
        (0u8..32).collect()
    }

    const NONCE: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
    const REQUEST: &[u8] = br#"{"id":"A","sent":1700000000,"op":"list"}"#;
    /// Onafhankelijk berekend (Python `cryptography`: HKDF-SHA256 met salt "nook-companion" en info "v1",
    /// ChaCha20-Poly1305 met AAD "630dcd2966c43366|q"), dus dezelfde bytes die CryptoKit op de Mac maakt.
    const REQUEST_SEALED: &str = "AAECAwQFBgcICQoL/Q9SIGxJgr1H181AE4xJD9cEaovDJP1OcBGi7PQJueDkK60SZr8z9gqwpfyVrbj6Z7+1SWuhTow=";
    const RESPONSE: &[u8] = br#"{"id":"A","ok":true}"#;
    const RESPONSE_SEALED: &str = "AAECAwQFBgcICQoL/Q9SIGxJgr1H181cHcAHWZ9AOMbbY0QcUFh62ldRSNjw234t";

    fn s(envelope: &[u8]) -> String {
        serde_json::from_slice::<Envelope>(envelope).unwrap().s
    }

    #[test]
    fn matches_the_test_vector() {
        let device = PairedDevice::identifier(&key());
        assert_eq!(device, "630dcd2966c43366");
        assert_eq!(s(&seal_with_nonce(REQUEST, &key(), &device, Direction::Request, NONCE)), REQUEST_SEALED);
        assert_eq!(s(&seal_with_nonce(RESPONSE, &key(), &device, Direction::Response, NONCE)), RESPONSE_SEALED);
    }

    #[test]
    fn opens_an_envelope_as_swift_writes_it() {
        // JSONEncoder zet `/` als `\/`.
        let swift = format!(r#"{{"d":"630dcd2966c43366","s":"{}"}}"#, REQUEST_SEALED.replace('/', "\\/"));
        assert_eq!(claimed_device(swift.as_bytes()).as_deref(), Some("630dcd2966c43366"));
        assert_eq!(open(swift.as_bytes(), &key(), Direction::Request).unwrap(), REQUEST);
    }

    #[test]
    fn round_trip_with_random_nonce() {
        let a = seal(b"hallo", &key(), "dev", Direction::Request);
        let b = seal(b"hallo", &key(), "dev", Direction::Request);
        assert_ne!(a, b, "elke keer een nieuwe nonce");
        assert_eq!(open(&a, &key(), Direction::Request).unwrap(), b"hallo");
    }

    #[test]
    fn refuses_wrong_key_direction_device_or_changes() {
        let sealed = seal(b"hallo", &key(), "dev", Direction::Request);
        assert_eq!(open(&sealed, &[7; 32], Direction::Request), Err(SealError::Authentication));
        assert_eq!(open(&sealed, &key(), Direction::Response), Err(SealError::Authentication));
        let mut envelope: Envelope = serde_json::from_slice(&sealed).unwrap();
        envelope.d = "other".into();
        assert_eq!(open(&serde_json::to_vec(&envelope).unwrap(), &key(), Direction::Request), Err(SealError::Authentication));
        let mut bytes = base64::engine::general_purpose::STANDARD.decode(s(&sealed)).unwrap();
        bytes[14] ^= 1;
        let changed = Envelope { d: "dev".into(), s: base64::engine::general_purpose::STANDARD.encode(bytes) };
        assert_eq!(open(&serde_json::to_vec(&changed).unwrap(), &key(), Direction::Request), Err(SealError::Authentication));
        assert_eq!(open(b"nonsense", &key(), Direction::Request), Err(SealError::Malformed));
        let short = Envelope { d: "dev".into(), s: base64::engine::general_purpose::STANDARD.encode([0u8; 28]) };
        assert_eq!(open(&serde_json::to_vec(&short).unwrap(), &key(), Direction::Request), Err(SealError::Malformed));
    }
}
