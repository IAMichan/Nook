// German, French, and Spanish for asking Nook about selected words (components/SelectionAsk.svelte), from the Mac's
// apps/macos/Core/I18n+SelectionAsk.swift.
import type { Table } from "./catalog";

export const table: Table = {
  "Ask Nook": { de: "Nook fragen", fr: "Demander à Nook", es: "Preguntar a Nook" },
  "Explain": { de: "Erklären", fr: "Expliquer", es: "Explicar" },
  "Translate": { de: "Übersetzen", fr: "Traduire", es: "Traducir" },
  "Answer this. If it is not a question, tell me what matters about it.": {
    de: "Beantworte das. Wenn es keine Frage ist, sag mir, worauf es dabei ankommt.",
    fr: "Réponds à ceci. Si ce n'est pas une question, dis-moi ce qui compte.",
    es: "Responde a esto. Si no es una pregunta, dime qué es lo importante.",
  },
  "Explain this in plain words.": { de: "Erkläre das in einfachen Worten.", fr: "Explique ceci avec des mots simples.", es: "Explica esto con palabras sencillas." },
  "Translate this into English.": { de: "Übersetze das ins Deutsche.", fr: "Traduis ceci en français.", es: "Traduce esto al español." },
  "Ask Nook about the selection": { de: "Nook zur Auswahl fragen", fr: "Demander à Nook à propos de la sélection", es: "Preguntar a Nook sobre la selección" },
  "Ask a follow-up…": { de: "Folgefrage stellen…", fr: "Poser une autre question…", es: "Haz otra pregunta…" },
  "Continue in chat": { de: "Im Chat fortsetzen", fr: "Continuer dans le chat", es: "Continuar en el chat" },
  "Close": { de: "Schließen", fr: "Fermer", es: "Cerrar" },
  "Copy": { de: "Kopieren", fr: "Copier", es: "Copiar" },
  "Copied": { de: "Kopiert", fr: "Copié", es: "Copiado" },
  "Send": { de: "Senden", fr: "Envoyer", es: "Enviar" },
  "Stop": { de: "Stoppen", fr: "Arrêter", es: "Detener" },
  "Ask about selected text": { de: "Zu markiertem Text fragen", fr: "Questions sur le texte sélectionné", es: "Preguntar sobre el texto seleccionado" },
  "Select words anywhere in Nook (a message, an answer, a pull request) and a small bar above them answers, explains or translates them right there, without opening the chat.": {
    de: "Markiere Wörter irgendwo in Nook (eine Nachricht, eine Antwort, einen Pull Request), und eine kleine Leiste darüber beantwortet, erklärt oder übersetzt sie direkt dort, ohne den Chat zu öffnen.",
    fr: "Sélectionnez des mots n'importe où dans Nook (un message, une réponse, une pull request) et une petite barre au-dessus y répond, les explique ou les traduit sur place, sans ouvrir le chat.",
    es: "Selecciona palabras en cualquier parte de Nook (un mensaje, una respuesta, una pull request) y una pequeña barra encima las responde, explica o traduce ahí mismo, sin abrir el chat.",
  },
};
