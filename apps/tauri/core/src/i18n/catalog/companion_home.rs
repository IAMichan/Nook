//! The companion's home and usage on Windows and Linux (`companion::home_digest`): the rows of "For you" and the plan
//! limits, worded as on the Mac.

use super::Row;

pub const ROWS: &[Row] = &[
    ("In progress", "Läuft gerade", "En cours", "En curso"),
    ("At {time}", "Um {time}", "À {time}", "A las {time}"),
    ("{agent} got stuck", "{agent} ist hängen geblieben", "{agent} est bloqué", "{agent} se atascó"),
    ("{agent} is waiting for you", "{agent} wartet auf dich", "{agent} vous attend", "{agent} te está esperando"),
    (
        "I was thinking along in {app} · {time}",
        "Ich habe in {app} mitgedacht · {time}",
        "Je réfléchissais avec vous dans {app} · {time}",
        "Estaba pensando contigo en {app} · {time}",
    ),
    (
        "Starts with your first message",
        "Startet mit deiner ersten Nachricht",
        "Commence avec votre premier message",
        "Empieza con tu primer mensaje",
    ),
    ("5 hours", "5 Std.", "5 heures", "5 horas"),
    ("Week", "Woche", "Semaine", "Semana"),
    ("Personal", "Persönlich", "Personnel", "Personal"),
    // The default model in the New session sheet (`companion::remote`).
    ("Default", "Standard", "Par défaut", "Predeterminado"),
];
