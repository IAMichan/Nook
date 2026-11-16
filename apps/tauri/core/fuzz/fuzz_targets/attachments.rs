//! A file dropped on the chat: reading it must give text or an error, never a panic. The first byte picks the kind of
//! file. PDFs are left out: pdf-extract can panic on odd files, which `read_text` catches on purpose, while libFuzzer
//! counts every panic as a crash.
#![no_main]

use libfuzzer_sys::fuzz_target;

const NAMES: [&str; 6] = ["a.docx", "a.odt", "a.pptx", "a.html", "a.txt", "a.bin"];

fuzz_target!(|data: &[u8]| {
    let Some((&kind, bytes)) = data.split_first() else { return };
    let name = NAMES[kind as usize % NAMES.len()];
    if let Ok(text) = nook_core::attachments::read_text(name, bytes) {
        assert!(!text.is_empty() && text.trim() == text, "read_text returns trimmed, non-empty text");
    }
});
