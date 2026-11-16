//! Companion frames (4-byte big-endian length, then the payload): bytes from the network in any chunking give the
//! same frames as reading them in one go, never more than MAX_FRAME, and a frame written with `frame` reads back.
#![no_main]

use libfuzzer_sys::fuzz_target;
use nook_core::companion::{FrameReader, MAX_FRAME};

fuzz_target!(|data: &[u8]| {
    let Some((&step, stream)) = data.split_first() else { return };
    let mut whole = FrameReader::default();
    let at_once = whole.feed(stream);
    let mut chunked = FrameReader::default();
    let mut frames = Vec::new();
    for chunk in stream.chunks(step as usize + 1) {
        frames.extend(chunked.feed(chunk));
    }
    assert_eq!(frames, at_once, "chunking does not change the frames");
    assert_eq!(chunked.overflowed(), whole.overflowed());
    assert!(frames.iter().all(|f| f.len() <= MAX_FRAME));

    if let Some(framed) = FrameReader::frame(stream) {
        assert_eq!(FrameReader::default().feed(&framed), vec![stream.to_vec()], "a written frame reads back");
    }
});
