//! The pairing link the iPhone scans (`nook://pair?h=…&p=…&k=…&n=…`): any text parses or is refused without a panic,
//! and a link that parses survives writing it out and reading it back.
#![no_main]

use libfuzzer_sys::fuzz_target;
use nook_core::companion::PairingLink;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    if let Some(link) = PairingLink::parse(text) {
        assert_eq!(PairingLink::parse(&link.url()).as_ref(), Some(&link), "url() of a parsed link parses to the same link");
    }
});
