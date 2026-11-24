//! Subscription limits read in the background, and Codex reset credits (AG-47, AG-49).

use super::Row;

pub const ROWS: &[Row] = &[
    ("This account no longer exists.", "Dieses Konto gibt es nicht mehr.", "Ce compte n’existe plus.", "Esta cuenta ya no existe."),
    ("Codex isn't on this computer.", "Codex ist nicht auf diesem Computer.", "Codex n’est pas sur cet ordinateur.", "Codex no está en este ordenador."),
    ("Quota", "Kontingent", "Quota", "Cuota"),
];
