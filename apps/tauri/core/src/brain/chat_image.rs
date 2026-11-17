//! An image the user gives Nook to look at (a dropped or pasted picture, a part of the screen). Brains that can see get
//! the image itself; every brain also gets the text in it, read on this computer, so a model without vision still
//! knows what it shows. Port of the Mac's `ChatImage.describe`.

/// The longest side a vision model reads at full detail (Claude: 1568 px); OCR reads a picture scaled to it too.
pub const MAX_SIDE: u32 = 1568;

/// The text that goes with the image for every brain: what Nook read in it, or that there is no text.
pub fn describe(name: &str, recognized: &str) -> String {
    let text = recognized.trim();
    if text.is_empty() {
        format!("Image: {name}. No readable text was found in it.")
    } else {
        format!("Image: {name}. Text recognized in the image (OCR, may contain small errors):\n{text}")
    }
}

/// The name of the `index`-th picture of a question, as the descriptions call it.
pub fn name(index: usize, count: usize) -> String {
    if count == 1 {
        "the attached picture".into()
    } else {
        format!("picture {}", index + 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_brain_learns_what_the_picture_says() {
        assert_eq!(describe("the attached picture", "  \n"), "Image: the attached picture. No readable text was found in it.");
        assert_eq!(
            describe("picture 2", " Invoice 2026-114\nTotal €120 "),
            "Image: picture 2. Text recognized in the image (OCR, may contain small errors):\nInvoice 2026-114\nTotal €120"
        );
        assert_eq!(name(0, 1), "the attached picture");
        assert_eq!(name(1, 3), "picture 2");
    }
}
