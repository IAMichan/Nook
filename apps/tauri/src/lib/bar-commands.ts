// What you can ask Nook, and what the bar itself can do, for the Commands tab. Add an entry whenever Nook learns a new
// trick or the bar gets a new function.
export type Pair = [nl: string, en: string];

/// Something to ask Nook: clicking it puts the text in the chat field.
export interface AskGroup {
  id: string;
  title: Pair;
  /** Shown under the title when the examples need something set up first. */
  note?: Pair;
  asks: Pair[];
}

export const askGroups: AskGroup[] = [
  {
    id: "agenda",
    title: ["Agenda", "Calendar"],
    note: ["Lezen werkt met je gekoppelde agenda's (ICS, Cal.com); toevoegen vraagt een agenda-koppeling die dat kan.", "Reading works with your connected calendars (ICS, Cal.com); adding needs a calendar connection that can write."],
    asks: [
      ["Zet morgen om 14:00 koffie met Lisa in mijn agenda", "Add coffee with Lisa to my calendar tomorrow at 2 pm"],
      ["Wat staat er morgen in mijn agenda?", "What is on my calendar tomorrow?"],
      ["Ben ik donderdagmiddag beschikbaar?", "Am I free on Thursday afternoon?"],
      ["Wanneer heb ik deze week een uur vrij?", "When do I have a free hour this week?"],
    ],
  },
  {
    id: "loops",
    title: ["Taken en onthouden", "Tasks and remembering"],
    asks: [
      ["Onthoud dat ik Lisa terugbel", "Remind me to call Lisa back"],
      ["Wat staat er nog open?", "What is still open?"],
      ["Vink \"Lisa terugbellen\" af", "Check off \"call Lisa back\""],
      ["Onthoud dat ik mijn koffie zwart drink", "Remember that I take my coffee black"],
      ["Wat weet je over mij?", "What do you know about me?"],
    ],
  },
  {
    id: "mail",
    title: ["Mail", "Mail"],
    asks: [
      ["Schrijf een mail aan Lisa dat ik later ben", "Write an email to Lisa that I'll be late"],
      ["Wat zit er vandaag in mijn inbox?", "What is in my inbox today?"],
    ],
  },
  {
    id: "screen",
    title: ["Scherm en apparaat", "Screen and device"],
    asks: [
      ["Wat zie je op mijn scherm?", "What do you see on my screen?"],
      ["Vat het geopende venster samen", "Summarise the open window"],
      ["Open Spotify", "Open Spotify"],
      ["Wat speelt er nu?", "What is playing now?"],
      ["Zet het volume op 30", "Set the volume to 30"],
      ["Wat zit er op mijn klembord?", "What is on my clipboard?"],
    ],
  },
  {
    id: "web",
    title: ["Web en bestanden", "Web and files"],
    asks: [
      ["Zoek op het web naar de beste Rust-tutorials", "Search the web for the best Rust tutorials"],
      ["Wat is het weer morgen?", "What is the weather tomorrow?"],
      ["Lees deze pagina en vat hem samen: ", "Read this page and summarise it: "],
      ["Zoek mijn bestanden over de offerte", "Find my files about the quote"],
      ["Maak een grafiek van mijn uitgaven", "Make a chart of my spending"],
    ],
  },
  {
    id: "calls",
    title: ["Gesprekken en code", "Calls and code"],
    asks: [
      ["Wat hebben we in het laatste gesprek besproken?", "What did we discuss in the last call?"],
      ["Welke pull requests wachten op mij?", "Which pull requests are waiting for me?"],
    ],
  },
];

/// What the bar itself can do.
export interface BarCommand {
  id: string;
  title: Pair;
  /** How you trigger it. */
  how: Pair;
  description: Pair;
}

export const barCommands: BarCommand[] = [
  {
    id: "open",
    title: ["Nook openen", "Open Nook"],
    how: ["Klik op het ronde Nook", "Click the round Nook"],
    description: ["De gesloten balk opent als paneel en blijft open tot Esc, een klik ernaast of tot het venster de focus verliest.", "The closed bar opens into the panel and stays open until Esc, a click elsewhere or the window loses focus."],
  },
  {
    id: "close",
    title: ["Nook sluiten", "Close Nook"],
    how: ["Esc, of klik ernaast", "Esc, or click elsewhere"],
    description: ["Sluit het paneel terug naar het ronde Nook. Wat je typte blijft in het veld staan.", "Closes the panel back to the round Nook. What you typed stays in the field."],
  },
  {
    id: "draft",
    title: ["Mijn concept bewaren", "Keep my draft"],
    how: ["Automatisch", "Automatic"],
    description: ["Niet-verstuurde tekst en bijlagen blijven in de chatbalk staan als je het paneel sluit, tot je ze verstuurt.", "Unsent text and attached files stay in the chat field when you close the panel, until you send them."],
  },
  {
    id: "drop",
    title: ["Bestand op Nook slepen", "Drop a file on Nook"],
    how: ["Sleep een bestand op het ronde Nook", "Drag a file onto the round Nook"],
    description: ["Nook kijkt omhoog als het bestand erboven hangt en slikt het door als je loslaat. Het paneel opent met het bestand in de chatbalk.", "Nook looks up as the file hovers and swallows it when you let go. The panel opens with the file in the chat field."],
  },
  {
    id: "attach",
    title: ["Een bestand bijvoegen", "Attach a file"],
    how: ["Paperclip, plakken, of slepen in het veld", "Paperclip, paste, or drag into the field"],
    description: ["Voeg afbeeldingen en documenten (tekst, PDF, Word) toe aan je bericht.", "Add images and documents (text, PDF, Word) to your message."],
  },
  {
    id: "resize",
    title: ["Paneel vergroten of verkleinen", "Resize the panel"],
    how: ["Sleep een rand of hoek van het open paneel", "Drag an edge or corner of the open panel"],
    description: ["Trek aan de linker-, rechter- of onderrand, of een onderhoek. Het gesloten Nook heeft een vaste maat.", "Pull the left, right or bottom edge, or a bottom corner. The closed Nook has a fixed size."],
  },
  {
    id: "history",
    title: ["Chatgeschiedenis", "Chat history"],
    how: ["Nook-tab, rechterkolom: Geschiedenis", "Nook tab, right column: History"],
    description: ["Al je gesprekken met zoeken, vastgezet en recent. Ga met de muis over een gesprek om het vast te zetten, te kopiëren, te archiveren of te verwijderen.", "All your chats with search, pinned and recent. Hover a chat to pin, copy, archive or delete it."],
  },
  {
    id: "language",
    title: ["Taal wisselen", "Switch language"],
    how: ["De NL/EN-knop in de kop", "The NL / EN button in the header"],
    description: ["Wisselt de taal van de interface en van Nooks antwoorden tussen Nederlands en Engels.", "Flips the interface and the language Nook answers in between Dutch and English."],
  },
  {
    id: "move",
    title: ["De balk verplaatsen", "Move the bar"],
    how: ["Sleep het ronde Nook of de kop van het paneel", "Drag the round Nook or the panel header"],
    description: ["Alleen als de balk zweeft in plaats van bovenaan het scherm hangt (Instellingen).", "Only when the bar floats instead of hanging at the top of the screen (Settings)."],
  },
];
