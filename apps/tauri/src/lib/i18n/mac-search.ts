// German, French, and Spanish for search everything (Ctrl+K) drawn as the Mac's `SearchPanel`, with the Mac's own
// wording (`search.*` in apps/macos/Core/I18n+Search.swift and I18n.swift). The Windows-only lines (the tips for what
// Windows can search, the Ctrl key hints) follow the same voice.
import type { Table } from "./catalog";

export const table: Table = {
  "Search conversations, sessions, chats, notes, settings…": { de: "Gespräche, Sitzungen, Chats, Notizen, Einstellungen durchsuchen…", fr: "Rechercher conversations, sessions, chats, notes, réglages…", es: "Busca en conversaciones, sesiones, chats, notas, ajustes…" },
  "New conversation with Nook": { de: "Neues Gespräch mit Nook", fr: "Nouvelle conversation avec Nook", es: "Nueva conversación con Nook" },
  "Open instructions and saved prompts": { de: "Anweisungen und gespeicherte Prompts öffnen", fr: "Ouvrir les instructions et les prompts enregistrés", es: "Abrir instrucciones y prompts guardados" },
  "Top hit": { de: "Bester Treffer", fr: "Meilleur résultat", es: "Mejor resultado" },
  "Open sessions: running, waiting on you or done": { de: "Offene Sitzungen: aktiv, warten auf dich oder fertig", fr: "Sessions en cours : actives, en attente de vous ou prêtes", es: "Sesiones abiertas: en curso, esperándote o listas" },
  "Settled sessions": { de: "Erledigte Sitzungen", fr: "Sessions classées", es: "Sesiones cerradas" },
  "Search more precisely": { de: "Genauer suchen", fr: "Chercher plus précisément", es: "Buscar con más precisión" },
  "exactly these words, in this order": { de: "genau diese Wörter, in dieser Reihenfolge", fr: "exactement ces mots, dans cet ordre", es: "exactamente estas palabras, en este orden" },
  "leave out what contains this word": { de: "lässt weg, was dieses Wort enthält", fr: "écarte ce qui contient ce mot", es: "deja fuera lo que contiene esta palabra" },
  "one or the other": { de: "das eine oder das andere", fr: "l’un ou l’autre", es: "una cosa u otra" },
  "after, before or on a date (also 7d, 2w, yesterday)": { de: "nach, vor oder an einem Datum (auch 7d, 2w, gestern)", fr: "après, avant ou à une date (aussi 7d, 2w, hier)", es: "después, antes o en una fecha (también 7d, 2w, ayer)" },
  "unread, pinned, running, failed, settled": { de: "ungelesen, angeheftet, aktiv, fehlgeschlagen, erledigt", fr: "non lu, épinglé, actif, échoué, réglé", es: "no leído, fijado, activo, fallido, resuelto" },
  "a regular expression": { de: "ein regulärer Ausdruck", fr: "une expression régulière", es: "una expresión regular" },
  "Try fewer words, another word, or remove a filter.": { de: "Versuche weniger Wörter, ein anderes Wort oder entferne einen Filter.", fr: "Essaie moins de mots, un autre mot, ou retire un filtre.", es: "Prueba con menos palabras, otra palabra o quita un filtro." },
  "Results": { de: "Ergebnisse", fr: "Résultats", es: "Resultados" },
  "Ask Nook: {text}": { de: "Nook fragen: {text}", fr: "Demander à Nook : {text}", es: "Preguntar a Nook: {text}" },
  "I found nothing about this in Nook. Try other words, or ask Nook in a conversation.": { de: "Dazu habe ich in Nook nichts gefunden. Versuche andere Wörter oder frag Nook im Gespräch.", fr: "Je n’ai rien trouvé à ce sujet dans Nook. Essaie d’autres mots ou demande à Nook dans une conversation.", es: "No encontré nada sobre esto en Nook. Prueba otras palabras o pregúntale a Nook en una conversación." },
  "only sessions, chats, notes, memory…": { de: "nur Sitzungen, Chats, Notizen, Gedächtnis…", fr: "seulement les sessions, chats, notes, la mémoire…", es: "solo sesiones, chats, notas, memoria…" },
  "what you, Nook, an agent or someone else wrote": { de: "was du, Nook, ein Agent oder jemand anderes schrieb", fr: "ce que toi, Nook, un agent ou quelqu’un d’autre a écrit", es: "lo que escribiste tú, Nook, un agente u otra persona" },
  "by app, project, branch or agent": { de: "nach App, Projekt, Branch oder Agent", fr: "par app, projet, branche ou agent", es: "por app, proyecto, rama o agente" },
  "Recently opened": { de: "Zuletzt geöffnet", fr: "Ouverts récemment", es: "Abiertos recientemente" },
  "Recent searches": { de: "Letzte Suchen", fr: "Recherches récentes", es: "Búsquedas recientes" },
  "AI answer": { de: "Antwort der KI", fr: "Réponse de l’IA", es: "Respuesta de la IA" },
  "Working out what to search for…": { de: "Überlege, wonach gesucht wird…", fr: "Je cherche quoi rechercher…", es: "Pensando qué buscar…" },
  "Reading {n} results…": { de: "{n} Ergebnisse werden gelesen…", fr: "Lecture de {n} résultats…", es: "Leyendo {n} resultados…" },
  "Choose a brain to search with AI. These are the closest results.": { de: "Wähle ein Gehirn, um mit KI zu suchen. Das sind die passendsten Ergebnisse.", fr: "Choisis un cerveau pour rechercher avec l’IA. Voici les résultats les plus proches.", es: "Elige un cerebro para buscar con IA. Estos son los resultados más cercanos." },
  "Choose brain": { de: "Gehirn wählen", fr: "Choisir un cerveau", es: "Elegir cerebro" },
  "The AI did not answer. These are the closest results.": { de: "Die KI hat nicht geantwortet. Das sind die passendsten Ergebnisse.", fr: "L’IA n’a pas répondu. Voici les résultats les plus proches.", es: "La IA no respondió. Estos son los resultados más cercanos." },
  "{n} matches": { de: "{n} Treffer", fr: "{n} occurrences", es: "{n} coincidencias" },
  "Search with AI: {text}": { de: "Mit KI suchen: {text}", fr: "Rechercher avec l’IA : {text}", es: "Buscar con IA: {text}" },
  "↑↓ choose · ⇥ kind · ↩ open · Ctrl↩ AI · Ctrl 1–9 jump · esc close": { de: "↑↓ wählen · ⇥ Art · ↩ öffnen · Strg↩ KI · Strg 1–9 direkt · esc schließen", fr: "↑↓ choisir · ⇥ type · ↩ ouvrir · Ctrl↩ IA · Ctrl 1–9 direct · esc fermer", es: "↑↓ elegir · ⇥ tipo · ↩ abrir · Ctrl↩ IA · Ctrl 1–9 directo · esc cerrar" },
};
