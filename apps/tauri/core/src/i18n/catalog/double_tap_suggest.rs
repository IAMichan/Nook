//! Double Tap suggestions and the line above the quick field (`services::double_tap_suggest`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Nook writes, changes or fills in where your cursor is, or does what you ask",
        "Nook schreibt, ändert oder füllt aus, wo dein Cursor steht, oder erledigt, was du sagst",
        "Nook écrit, modifie ou remplit là où se trouve votre curseur, ou fait ce que vous demandez",
        "Nook escribe, cambia o rellena donde está tu cursor, o hace lo que le pidas",
    ),
    (
        "{app} · Nook writes or changes text at your cursor",
        "{app} · Nook schreibt oder ändert Text an deinem Cursor",
        "{app} · Nook écrit ou modifie le texte à votre curseur",
        "{app} · Nook escribe o cambia texto en tu cursor",
    ),
    ("Via your browser", "Über deinen Browser", "Via votre navigateur", "Con tu navegador"),
    (
        "{app} · {n} empty fields: Nook can fill them in",
        "{app} · {n} leere Felder: Nook kann sie ausfüllen",
        "{app} · {n} champs vides : Nook peut les remplir",
        "{app} · {n} campos vacíos: Nook puede rellenarlos",
    ),
    (
        "{app} · {n} empty field: Nook can fill it in",
        "{app} · {n} leeres Feld: Nook kann es ausfüllen",
        "{app} · {n} champ vide : Nook peut le remplir",
        "{app} · {n} campo vacío: Nook puede rellenarlo",
    ),
    (
        "{app} · Looking at what is in front…",
        "{app} · Schaut, was vor dir liegt…",
        "{app} · Regarde ce qui est devant vous…",
        "{app} · Mirando lo que tienes delante…",
    ),
    (
        "{app} · Reply box: Nook can write the reply",
        "{app} · Antwortfeld: Nook kann die Antwort schreiben",
        "{app} · Zone de réponse : Nook peut écrire la réponse",
        "{app} · Cuadro de respuesta: Nook puede escribir la respuesta",
    ),
    (
        "{app} · {n} words selected: improve, translate or explain them",
        "{app} · {n} Wörter markiert: verbessern, übersetzen oder erklären",
        "{app} · {n} mots sélectionnés : améliorer, traduire ou expliquer",
        "{app} · {n} palabras seleccionadas: mejorar, traducir o explicar",
    ),
    (
        "{app} · {n} word selected: improve, translate or explain it",
        "{app} · {n} Wort markiert: verbessern, übersetzen oder erklären",
        "{app} · {n} mot sélectionné : améliorer, traduire ou expliquer",
        "{app} · {n} palabra seleccionada: mejorar, traducir o explicar",
    ),
    (
        "{app} · Nook can read this window and act on it",
        "{app} · Nook kann dieses Fenster lesen und damit arbeiten",
        "{app} · Nook peut lire cette fenêtre et s’en occuper",
        "{app} · Nook puede leer esta ventana y encargarse",
    ),
    ("Put this in my calendar", "Trag das in meinen Kalender ein", "Mets ça dans mon agenda", "Pon esto en mi calendario"),
    ("Write more", "Schreibe weiter", "Écris la suite", "Escribe la continuación"),
    ("Explain the selected text", "Erkläre den markierten Text", "Explique le texte sélectionné", "Explica el texto seleccionado"),
    ("Fill in the form", "Füll das Formular aus", "Remplis le formulaire", "Rellena el formulario"),
    ("Improve this", "Verbessere das", "Améliore ce texte", "Mejora esto"),
    ("Write a reply", "Schreibe eine Antwort", "Écris une réponse", "Escribe una respuesta"),
    ("Shorten this", "Kürze das", "Raccourcis ce texte", "Acorta esto"),
    ("Summarize this window", "Fasse dieses Fenster zusammen", "Résume cette fenêtre", "Resume esta ventana"),
    ("Translate this into {language}", "Übersetze das auf {language}", "Traduis ceci en {language}", "Traduce esto al {language}"),
    ("Nook doesn't type in {app}", "Nook tippt nicht in {app}", "Nook ne tape pas dans {app}", "Nook no escribe en {app}"),
    ("Dutch", "Niederländisch", "néerlandais", "neerlandés"),
    ("German", "Deutsch", "allemand", "alemán"),
    ("French", "Französisch", "français", "francés"),
    ("Spanish", "Spanisch", "espagnol", "español"),
    ("English", "Englisch", "anglais", "inglés"),
];
