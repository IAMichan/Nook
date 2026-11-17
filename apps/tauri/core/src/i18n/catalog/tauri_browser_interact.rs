//! Rows added with `tauri-browser-interact`; a feature keeps its own catalog file (see `catalog/mod.rs`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Nook browser elements", "Elemente im Nook-Browser", "Éléments du navigateur Nook", "Elementos del navegador de Nook"),
    ("Click in Nook browser", "Im Nook-Browser klicken", "Cliquer dans le navigateur Nook", "Clic en el navegador de Nook"),
    ("Type in Nook browser", "Im Nook-Browser tippen", "Saisir dans le navigateur Nook", "Escribir en el navegador de Nook"),
    ("Wait for Nook browser", "Auf den Nook-Browser warten", "Attendre le navigateur Nook", "Esperar al navegador de Nook"),
    (
        "{agent} wants to click on {host}",
        "{agent} möchte auf {host} klicken",
        "{agent} veut cliquer sur {host}",
        "{agent} quiere hacer clic en {host}",
    ),
    (
        "{agent} wants to type on {host}",
        "{agent} möchte auf {host} tippen",
        "{agent} veut saisir du texte sur {host}",
        "{agent} quiere escribir en {host}",
    ),
    (
        "This page is not on your computer: a click or typed text can send something on your behalf.",
        "Diese Seite liegt nicht auf deinem Computer: Ein Klick oder getippter Text kann in deinem Namen etwas senden.",
        "Cette page n'est pas sur votre ordinateur : un clic ou un texte saisi peut envoyer quelque chose en votre nom.",
        "Esta página no está en tu ordenador: un clic o un texto escrito puede enviar algo en tu nombre.",
    ),
];
