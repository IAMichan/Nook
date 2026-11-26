//! Translations for per-kind text generation API errors (`TextGenerators.swift`, SV-65).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "This service has no valid address.",
        "Dieser Dienst hat keine gültige Adresse.",
        "Ce service n’a pas d’adresse valide.",
        "Este servicio no tiene una dirección válida.",
    ),
    (
        "{name} needs an API key. Until it has one, the coding agent writes this text.",
        "{name} braucht einen API-Schlüssel. Bis dahin schreibt der Coding-Agent diesen Text.",
        "{name} a besoin d’une clé API. En attendant, l’agent de code écrit ce texte.",
        "{name} necesita una clave API. Hasta que la tenga, el agente de código escribe este texto.",
    ),
    (
        "The key was refused: {msg}",
        "Der Schlüssel wurde abgelehnt: {msg}",
        "La clé a été refusée : {msg}",
        "La clave fue rechazada: {msg}",
    ),
    (
        "The model was not found: {msg}",
        "Das Modell wurde nicht gefunden: {msg}",
        "Modèle introuvable : {msg}",
        "No se encontró el modelo: {msg}",
    ),
    (
        "Too many requests. Try again in a moment.",
        "Zu viele Anfragen. Versuche es gleich noch einmal.",
        "Trop de requêtes. Réessayez dans un instant.",
        "Demasiadas peticiones. Inténtalo de nuevo en un momento.",
    ),
    (
        "The service answered with error {code}: {msg}",
        "Der Dienst antwortete mit Fehler {code}: {msg}",
        "Le service a répondu avec l’erreur {code} : {msg}",
        "El servicio respondió con el error {code}: {msg}",
    ),
    (
        "The model answered without any text.",
        "Das Modell antwortete ohne Text.",
        "Le modèle a répondu sans texte.",
        "El modelo respondió sin texto.",
    ),
];
