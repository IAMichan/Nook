//! The shared golden fixtures of the companion protocol (`packages/protocol/Fixtures`), read here as on the Mac
//! (`CompanionFixturesTests`) and in the relay (`apps/relay/test/fixtures.test.js`), so the three stay byte for byte
//! the same. See the parity table in `docs/COMPANION.md`.

use serde_json::Value;

use super::models::{base64url_decode, CompanionRequest, CompanionResponse, FrameReader, PairedDevice, PairingLink, MAX_FRAME};
use super::seal::{open, seal_with_nonce, Direction};

fn fixture(name: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packages/protocol/Fixtures").join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap()
}

fn hex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn str_of<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or_else(|| panic!("{key} missing"))
}

#[test]
fn sealed_frames_match() {
    let f = fixture("sealed.json");
    let key = base64url_decode(str_of(&f, "key")).unwrap();
    let device = str_of(&f, "deviceID");
    assert_eq!(PairedDevice::identifier(&key), device);
    let nonce: [u8; 12] = hex(str_of(&f, "nonce")).try_into().unwrap();
    for vector in f["vectors"].as_array().unwrap() {
        let direction = if str_of(vector, "direction") == "q" { Direction::Request } else { Direction::Response };
        let plaintext = str_of(vector, "plaintext").as_bytes();
        let envelope = seal_with_nonce(plaintext, &key, device, direction, nonce);
        let parsed: Value = serde_json::from_slice(&envelope).unwrap();
        assert_eq!(str_of(&parsed, "s"), str_of(vector, "s"));
        assert_eq!(str_of(&parsed, "d"), device);
        assert_eq!(open(&envelope, &key, direction).unwrap(), plaintext);
    }
}

#[test]
fn framing_matches() {
    let f = fixture("framing.json");
    assert_eq!(f["maxFrame"].as_u64().unwrap() as usize, MAX_FRAME);
    for frame in f["frames"].as_array().unwrap() {
        let payload = hex(str_of(frame, "payload"));
        let framed = hex(str_of(frame, "framed"));
        assert_eq!(FrameReader::frame(&payload).unwrap(), framed);
        assert_eq!(FrameReader::default().feed(&framed), vec![payload]);
    }
}

#[test]
fn pairing_links_match() {
    let f = fixture("pairing.json");
    for link in f["valid"].as_array().unwrap() {
        let parsed = PairingLink::parse(str_of(link, "url")).unwrap_or_else(|| panic!("{}", str_of(link, "url")));
        assert_eq!(parsed.host, str_of(link, "host"));
        assert_eq!(parsed.port as u64, link["port"].as_u64().unwrap());
        assert_eq!(parsed.key, base64url_decode(str_of(link, "key")).unwrap());
        assert_eq!(parsed.mac_name, str_of(link, "macName"));
    }
    for text in f["invalid"].as_array().unwrap() {
        assert_eq!(PairingLink::parse(text.as_str().unwrap()), None, "{text}");
    }
}

#[test]
fn core_requests_and_responses_read_and_write_back() {
    for entry in fixture("requests.json")["requests"].as_array().unwrap() {
        if entry["core"] != Value::Bool(true) {
            continue;
        }
        let request: CompanionRequest = serde_json::from_value(entry["json"].clone()).unwrap();
        let back = serde_json::to_value(&request).unwrap();
        // Numbers come back as floats (Swift's Double), so the written JSON is compared by reading it again.
        assert_eq!(serde_json::from_value::<CompanionRequest>(back.clone()).unwrap(), request);
        assert_eq!(back.as_object().unwrap().len(), entry["json"].as_object().unwrap().len(),
                   "{}: every field is known and written back", str_of(entry, "name"));
        assert_eq!(back["op"], entry["json"]["op"]);
        assert_eq!(request.sent, entry["json"]["sent"].as_f64().unwrap());
    }
    for entry in fixture("responses.json")["responses"].as_array().unwrap() {
        if entry["core"] != Value::Bool(true) {
            continue;
        }
        let response: CompanionResponse = serde_json::from_value(entry["json"].clone()).unwrap();
        assert_eq!(response.id, str_of(&entry["json"], "id"));
        assert_eq!(response.ok, entry["json"]["ok"].as_bool().unwrap());
        let back = serde_json::to_value(&response).unwrap();
        assert_eq!(serde_json::from_value::<CompanionResponse>(back.clone()).unwrap(), response);
        // What this implementation knows comes back under the same names; fields it does not know are left out.
        for field in back.as_object().unwrap().keys() {
            assert!(entry["json"].get(field).is_some(), "{} wrote {field}", str_of(entry, "name"));
        }
        assert_eq!(response.sessions.as_ref().map(Vec::len), entry["json"]["sessions"].as_array().map(Vec::len));
    }
}
