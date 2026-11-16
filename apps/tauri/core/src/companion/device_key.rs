//! A phone's own signing key, next to the pairing key both sides share (`CompanionDeviceKey.swift`, docs/COMPANION.md,
//! "Device key").
//!
//! The pairing key seals every message; whoever holds a copy of it (a backup, a leaked file) could seal requests too.
//! The device key closes that: the phone makes a P-256 key that stays on it, tells a computer that lists
//! `feature::DEVICE_KEY` its public half once (`CompanionOp::BindKey`), and from then on signs every request (envelope
//! field `g`, `seal::attach`). The computer refuses an unsigned or wrongly signed request from that phone, except
//! `ping`, so a copied pairing key alone can no longer act. The first key a computer hears for a pairing is the one it
//! keeps (trust on first use); unpairing forgets it on both sides.
//!
//! Signatures are ECDSA P-256 with SHA-256 as their 64 raw bytes (`r || s`), public keys X9.63 (65 bytes,
//! uncompressed), as CryptoKit writes them.

use p256::ecdsa::signature::{Signer, Verifier};
use p256::ecdsa::{Signature, SigningKey, VerifyingKey};
use rand::TryRng;

use super::models::CompanionOp;
use super::seal;

/// A new private key, as its 32 bytes.
pub fn generate() -> Option<Vec<u8>> {
    for _ in 0..8 {
        let mut bytes = [0u8; 32];
        rand::rngs::SysRng.try_fill_bytes(&mut bytes).ok()?;
        if SigningKey::from_slice(&bytes).is_ok() {
            return Some(bytes.to_vec());
        }
    }
    None
}

/// The public half (X9.63) of a private key made by `generate`.
pub fn public_key(private: &[u8]) -> Option<Vec<u8>> {
    let key = SigningKey::from_slice(private).ok()?;
    Some(key.verifying_key().to_sec1_point(false).as_bytes().to_vec())
}

/// `envelope` signed with `private` (`g`); `None` when the key or the envelope is not usable.
pub fn sign(envelope: &[u8], private: &[u8]) -> Option<Vec<u8>> {
    let key = SigningKey::from_slice(private).ok()?;
    let bytes = seal::signed_bytes(envelope)?;
    let signature: Signature = key.sign(&bytes);
    seal::attach(&signature.to_bytes(), envelope)
}

/// Whether the public key as a phone sends it (X9.63) is a P-256 point.
pub fn is_valid_public_key(data: &[u8]) -> bool {
    VerifyingKey::from_sec1_bytes(data).is_ok()
}

/// Whether `envelope` carries a valid signature by `public_key` over what it seals. CryptoKit does not normalise `s`,
/// so a high-`s` signature from an iPhone is taken as it is.
pub fn verify(envelope: &[u8], public_key: &[u8]) -> bool {
    let (Ok(key), Some(bytes), Some(raw)) =
        (VerifyingKey::from_sec1_bytes(public_key), seal::signed_bytes(envelope), seal::signature(envelope))
    else {
        return false;
    };
    let Ok(signature) = Signature::from_slice(&raw) else { return false };
    let signature = signature.normalize_s();
    key.verify(&bytes, &signature).is_ok()
}

/// The ops a computer takes without a signature from a phone whose key it holds: `ping` alone, as it carries and
/// returns nothing.
pub fn needs_signature(op: CompanionOp) -> bool {
    op != CompanionOp::Ping
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;
    /// Made by CryptoKit on a Mac: the key with private bytes [7; 32] signing `630dcd2966c43366|<REQUEST_SEALED>` of the
    /// seal's test vector, once with a low and once with a high `s`.
    const PUBLIC: &str = "BB4YUy/UdUwC8wQdnHXOszuD/9gax85P6ILMscmLxYlupGwxHE4v9A3ZajZT5uRURdMt/khuztdcepDGoYiBwKM=";
    const LOW_S: &str = "py4Sftr50igjn7BffXODsefvIpzFj/B0bdZ7pcMMusQQ/MZ0nFENyKsc60Ybw8jfKIkCc/PLpvrDGKEegfZA7A==";
    const HIGH_S: &str = "AZwnybf1MGQGzvFruHK6XqlX1mS42slHlpUdwGrYpkG1dx2sKCRYo9p9B6VMYPmbkk3Q6dR0ClCfzOdl5qvXTA==";
    const ENVELOPE: &str =
        r#"{"d":"630dcd2966c43366","s":"AAECAwQFBgcICQoL/Q9SIGxJgr1H181AE4xJD9cEaovDJP1OcBGi7PQJueDkK60SZr8z9gqwpfyVrbj6Z7+1SWuhTow="}"#;

    #[test]
    fn verifies_what_cryptokit_signs() {
        let public = B64.decode(PUBLIC).unwrap();
        assert_eq!(public_key(&[7u8; 32]).unwrap(), public, "the same public key as CryptoKit's x963Representation");
        for signature in [LOW_S, HIGH_S] {
            let signed = seal::attach(&B64.decode(signature).unwrap(), ENVELOPE.as_bytes()).unwrap();
            assert!(verify(&signed, &public), "{signature}");
        }
        assert!(!verify(ENVELOPE.as_bytes(), &public), "unsigned");
    }

    #[test]
    fn a_signature_is_for_its_own_key_and_message() {
        let private = generate().unwrap();
        let public = public_key(&private).unwrap();
        let envelope = seal::seal(br#"{"id":"r","sent":1,"op":"list"}"#, &[7; 32], "dev", seal::Direction::Request);
        let signed = sign(&envelope, &private).unwrap();
        assert!(verify(&signed, &public));
        assert!(!verify(&signed, &public_key(&generate().unwrap()).unwrap()), "another key");
        let other = seal::seal(br#"{"id":"x","sent":1,"op":"stop"}"#, &[7; 32], "dev", seal::Direction::Request);
        let moved = seal::attach(&seal::signature(&signed).unwrap(), &other).unwrap();
        assert!(!verify(&moved, &public), "a signature does not carry over to another message");
        // The signature does not get in the way of opening it.
        assert_eq!(seal::open(&signed, &[7; 32], seal::Direction::Request).unwrap(), br#"{"id":"r","sent":1,"op":"list"}"#);
    }

    #[test]
    fn only_a_p256_point_is_a_key_and_ping_needs_no_signature() {
        assert!(is_valid_public_key(&public_key(&generate().unwrap()).unwrap()));
        assert!(!is_valid_public_key(&[1u8; 65]));
        assert!(!needs_signature(CompanionOp::Ping));
        assert!(needs_signature(CompanionOp::Decide));
        assert!(needs_signature(CompanionOp::BindKey));
    }

    #[test]
    fn an_unsigned_envelope_is_as_before() {
        let envelope = seal::seal(b"x", &[7; 32], "dev", seal::Direction::Request);
        let object: serde_json::Value = serde_json::from_slice(&envelope).unwrap();
        assert_eq!(object.as_object().unwrap().len(), 2, "nothing new in an unsigned envelope");
    }
}
