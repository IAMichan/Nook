// German, French, and Spanish for the steps Nook suggests from a conversation (`ActionSuggestionBar`, Settings ›
// Autocomplete), with the Mac's own wording (`suggestActions.*`, `chats.draft.actions*` in apps/macos/Core).
import type { Table } from "./catalog";

export const table: Table = {
  "Nook suggests": { de: "Nook schlägt vor", fr: "Nook propose", es: "Nook propone" },
  "Do it": { de: "Ausführen", fr: "Exécuter", es: "Hacerlo" },
  "Let this proposal go": { de: "Diesen Vorschlag verwerfen", fr: "Ignorer cette proposition", es: "Descartar esta propuesta" },
  "{n} actions completed": { de: "{n} Aktionen ausgeführt", fr: "{n} actions effectuées", es: "{n} acciones completadas" },
  "{n} steps done": { de: "{n} Schritte ausgeführt", fr: "{n} étapes exécutées", es: "{n} pasos hechos" },
  "Adjust first": { de: "Erst anpassen", fr: "Ajuster d’abord", es: "Ajustar primero" },
  "Running…": { de: "Läuft…", fr: "Exécution…", es: "Ejecutando…" },
  "Suggest actions from conversations": { de: "Aktionen aus Gesprächen vorschlagen", fr: "Suggérer des actions à partir des conversations", es: "Sugerir acciones a partir de las conversaciones" },
  "In an open chat, an agent's session and Nook Chat, Nook reads the newest messages and offers what it can do for them above the field, such as starting an agent on a task that came up. Nothing runs until you click Do it. Nook only suggests a step that saves you real work and is filled in completely, such as a coding task with its project; reactions and vague ideas get nothing.": { de: "In einem offenen Chat, einer Agent-Sitzung und im Nook Chat liest Nook die neuesten Nachrichten und bietet über dem Eingabefeld an, was es dafür tun kann, etwa einen Agenten für eine Aufgabe starten, die zur Sprache kam. Nichts passiert, bis du auf Ausführen klickst. Nook schlägt nur einen Schritt vor, der dir echte Arbeit abnimmt und vollständig ausgefüllt ist, etwa eine Programmieraufgabe mit ihrem Projekt; Reaktionen und vage Ideen bekommen nichts.", fr: "Dans une discussion ouverte, une session d’agent et Nook Chat, Nook lit les derniers messages et propose au-dessus du champ ce qu’il peut faire, comme lancer un agent sur une tâche évoquée. Rien ne s’exécute avant que vous cliquiez sur Exécuter. Nook ne propose qu’une étape qui vous épargne un vrai travail et qui est entièrement remplie, comme une tâche de code avec son projet ; les réactions et les idées vagues n’obtiennent rien.", es: "En un chat abierto, una sesión de agente y Nook Chat, Nook lee los mensajes más recientes y ofrece encima del campo lo que puede hacer, como iniciar un agente en una tarea que surgió. No se ejecuta nada hasta que haces clic en Hacerlo. Nook solo sugiere un paso que te ahorra trabajo real y está completo, como una tarea de código con su proyecto; las reacciones y las ideas vagas no reciben nada." },
  "Model for suggestions": { de: "Modell für Vorschläge", fr: "Modèle pour les suggestions", es: "Modelo para las sugerencias" },
  "Same model as the brain (default)": { de: "Gleiches Modell wie das Gehirn (Standard)", fr: "Même modèle que le cerveau (par défaut)", es: "Mismo modelo que el cerebro (predeterminado)" },
};
