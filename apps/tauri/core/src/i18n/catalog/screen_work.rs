//! The brain: screen work on a model on this computer (`screen_work`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Looking things up…", "Ich schlage nach…", "Je cherche…", "Estoy buscando…"),
    (
        "Answered by {name} on this computer, because it is about your screen.",
        "Beantwortet von {name} auf diesem Computer, weil es um deinen Bildschirm geht.",
        "Répondu par {name} sur cet ordinateur, car il s’agit de votre écran.",
        "Respondido por {name} en este ordenador, porque trata de tu pantalla.",
    ),
    (
        "Your chosen brain looked things up without seeing your screen; {name} read your screen and wrote this answer on this computer.",
        "Dein gewähltes Gehirn hat nachgeschlagen, ohne deinen Bildschirm zu sehen; {name} hat ihn gelesen und diese Antwort auf diesem Computer geschrieben.",
        "Votre cerveau choisi a cherché sans voir votre écran ; {name} l’a lu et a écrit cette réponse sur cet ordinateur.",
        "Tu cerebro elegido buscó sin ver tu pantalla; {name} la leyó y escribió esta respuesta en este ordenador.",
    ),
    ("Reading on this computer…", "Liest auf diesem Computer…", "Lecture sur cet ordinateur…", "Leyendo en este ordenador…"),
    (
        "{name} read this on your computer and gave {chosen} a filtered note, so it could answer.",
        "{name} hat auf deinem Computer gelesen und {chosen} eine gefilterte Notiz gegeben, damit es antworten konnte.",
        "{name} a lu ceci sur votre ordinateur et a donné une note filtrée à {chosen} pour qu’il puisse répondre.",
        "{name} leyó esto en tu ordenador y dio una nota filtrada a {chosen} para que pudiera responder.",
    ),
    ("Thinking…", "Denke nach…", "Réflexion…", "Pensando…"),
    (
        "Controlling apps is not supported on this platform.",
        "Das Steuern von Apps wird auf dieser Plattform nicht unterstützt.",
        "Le contrôle des applications n’est pas pris en charge sur cette plateforme.",
        "Controlar aplicaciones no es compatible con esta plataforma.",
    ),
];
