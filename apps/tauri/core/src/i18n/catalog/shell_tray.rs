//! The tray menu's status lines and tooltip, as the Mac's menu bar menu says them (`menu.*`, `update.menu.*`,
//! `autocomplete.menuBarCount.tooltip` in apps/macos/Core).

use super::Row;

pub const ROWS: &[Row] = &[
    ("now", "jetzt", "maintenant", "ahora"),
    ("{n} agents running, {w} waiting for you", "{n} Agents aktiv, {w} warten auf dich", "{n} agents en cours, {w} en attente de vous", "{n} agentes en ejecución, {w} esperándote"),
    ("{n} agents running", "{n} Agents aktiv", "{n} agents en cours", "{n} agentes en ejecución"),
    ("Needs you: {title}", "Wartet auf dich: {title}", "T’attend : {title}", "Te espera: {title}"),
    ("Update to Nook {version}…", "Auf Nook {version} aktualisieren…", "Mettre à jour vers Nook {version}…", "Actualizar a Nook {version}…"),
    ("Updating Nook…", "Nook wird aktualisiert…", "Mise à jour de Nook…", "Actualizando Nook…"),
    ("Restart Nook to finish the update", "Nook neu starten, um das Update abzuschließen", "Redémarrer Nook pour terminer la mise à jour", "Reinicia Nook para terminar la actualización"),
    ("The update did not finish", "Das Update wurde nicht abgeschlossen", "La mise à jour n'a pas abouti", "La actualización no terminó"),
    ("{n} words completed today", "{n} Wörter heute vervollständigt", "{n} mots complétés aujourd’hui", "{n} palabras completadas hoy"),
    ("Pause", "Pausieren", "Pause", "Pausa"),
    ("Play", "Abspielen", "Lecture", "Reproducir"),
    ("Next track", "Nächster Titel", "Piste suivante", "Siguiente pista"),
    ("Pause autocomplete", "Vervollständigung pausieren", "Mettre la complétion en pause", "Pausar autocompletado"),
    ("Resume autocomplete", "Vervollständigung fortsetzen", "Reprendre la complétion", "Reanudar autocompletado"),
];
