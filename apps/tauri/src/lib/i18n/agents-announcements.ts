// German, French, and Spanish for what a screen reader hears from a session (`ws.announce.*` on the Mac).
import type { Table } from "./catalog";

export const table: Table = {
  "{author}: {text}": { de: "{author}: {text}", fr: "{author} : {text}", es: "{author}: {text}" },
  "{author} needs your approval": { de: "{author} braucht deine Freigabe", fr: "{author} attend votre accord", es: "{author} necesita tu aprobación" },
  "{author} asks you a question": { de: "{author} stellt dir eine Frage", fr: "{author} vous pose une question", es: "{author} te hace una pregunta" },
  "code block": { de: "Codeblock", fr: "bloc de code", es: "bloque de código" },
  "More in the conversation.": { de: "Mehr im Gespräch.", fr: "La suite dans la conversation.", es: "Más en la conversación." },
};
