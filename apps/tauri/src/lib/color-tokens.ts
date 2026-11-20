// The colors you can set one by one (Settings › Appearance › Custom colors, `NookColorToken.all` on the Mac): each
// token's group, its CSS variable in app.css, its name and where it shows, in the Mac's words.
import { tr } from "./i18n.svelte";

export type ColorGroup = "surfaces" | "lines" | "text" | "state" | "changes" | "chat" | "code";

export const COLOR_GROUPS: ColorGroup[] = ["surfaces", "lines", "text", "state", "changes", "chat", "code"];

export interface ColorToken { id: string; group: ColorGroup; cssVar: string; title: () => string; info: () => string }

export const COLOR_TOKENS: ColorToken[] = [
  { id: "canvas", group: "surfaces", cssVar: "--canvas", title: () => tr("Achtergrond", "Background"), info: () => tr("De achtergrond van het hoofdvenster, Instellingen en het zijpaneel met wijzigingen, bestanden en de browser. Al het andere ligt hierop.", "The back of the main window, Settings and the side panel with changes, files and the browser. Everything else sits on it.") },
  { id: "well", group: "surfaces", cssVar: "--well", title: () => tr("Verzonken vlak", "Recessed area"), info: () => tr("Verzonken blokken onder de achtergrond: code en uitvoer van commando's, voorbeelden, goedkeuringen en antwoordopties.", "Sunken blocks below the background: code and command output, previews, approvals and answer options.") },
  { id: "surface", group: "surfaces", cssVar: "--surface", title: () => tr("Kaarten en panelen", "Cards and panels"), info: () => tr("Kaarten en panelen op de achtergrond: de zijbalk, kaarten, vensters die openschuiven en het paneel in de balk.", "Cards and panels on the background: the sidebar, cards, sheets and the panel in the bar.") },
  { id: "composer", group: "surfaces", cssVar: "--composer", title: () => tr("Composer", "Composer"), info: () => tr("Het veld waarin je typt onder een sessie en een chat.", "The field you type in under a session and a chat.") },
  { id: "composerTray", group: "surfaces", cssVar: "--composer-tray", title: () => tr("Composer-lades en -balken", "Composer trays and bars"), info: () => tr("De stroken die boven en onder de composer uitkomen: de pull request die een sessie volgt, en de worktree en branch waarmee een nieuwe sessie begint; de balken erboven voor achtergrondcommando's, taken, subagents en zijchats; en het invoerveld van een chat zolang je er niet in typt. Volgt de composer tot je hem zelf instelt.", "The strips that come out above and below the composer: the pull request a session watches, and the worktree and branch a new session starts from; the bars above it for background commands, tasks, subagents and side chats; and a chat's field while you are not typing in it. Follows the composer until you set it yourself.") },
  { id: "menu", group: "surfaces", cssVar: "--menu", title: () => tr("Menu's en tooltips", "Menus and tooltips"), info: () => tr("Menu's, uitklaplijsten, hoverkaarten en tooltips. De tekst erop is voor donker, dus houd dit een donkere kleur.", "Menus, dropdowns, hover cards and tooltips. Their text is drawn for dark, so keep this a dark color.") },
  { id: "field", group: "surfaces", cssVar: "--field", title: () => tr("Invoervelden", "Input fields"), info: () => tr("Invoer- en zoekvelden, en kleine blokjes in tekst zoals code en labels.", "Input and search fields, and small blocks inside text such as inline code and tags.") },
  { id: "graphite", group: "surfaces", cssVar: "--graphite", title: () => tr("Verhoogde knoppen", "Raised controls"), info: () => tr("Verhoogde knoppen, chips en badges die op een kaart staan.", "Raised buttons, chips and badges that stand on a card.") },
  { id: "smoke", group: "surfaces", cssVar: "--smoke", title: () => tr("Knoppen bij hover", "Controls on hover"), info: () => tr("Een knop of bediening terwijl de aanwijzer erop staat, en een ingedrukte of gekozen chip.", "A button or control while the pointer is on it, and a pressed or chosen chip.") },
  { id: "rowRest", group: "surfaces", cssVar: "--row-rest", title: () => tr("Rij", "Row"), info: () => tr("Een rij in lijsten van kaartjes, zoals mail en workflowruns, in rust.", "A row in lists drawn as rows of cards, such as mail and workflow runs, while nothing happens to it.") },
  { id: "rowHover", group: "surfaces", cssVar: "--row-hover", title: () => tr("Rij bij hover", "Row on hover"), info: () => tr("Een rij in een lijst onder de aanwijzer.", "A list row under the pointer.") },
  { id: "rowSelected", group: "surfaces", cssVar: "--row-selected", title: () => tr("Geselecteerde rij", "Selected row"), info: () => tr("De rij die je hebt gekozen of geopend, in elke lijst.", "The row you selected or opened, in every list.") },
  { id: "bubble", group: "surfaces", cssVar: "--bubble", title: () => tr("Jouw bericht", "Your message"), info: () => tr("Je eigen berichten in een sessie met een codeeragent en in de Nook-chat.", "Your own messages in a session with a coding agent and in the Nook chat.") },
  { id: "line", group: "lines", cssVar: "--line", title: () => tr("Lijn", "Line"), info: () => tr("De rand van panelen en kaarten, en dunne balkjes zoals voortgangssporen.", "The outline of panels and cards, and thin bars such as progress tracks.") },
  { id: "line2", group: "lines", cssVar: "--line2", title: () => tr("Sterke lijn", "Strong line"), info: () => tr("Sterkere lijnen: randen van bedieningen, tabellen, grafieken en codeblokken.", "Stronger lines: outlines of controls, tables, charts and code blocks.") },
  { id: "hairline", group: "lines", cssVar: "--hairline", title: () => tr("Haarlijn", "Hairline"), info: () => tr("De fijnste lijnen, zoals rond linkvoorbeelden in chats.", "The finest lines, such as around link previews in chats.") },
  { id: "border", group: "lines", cssVar: "--border", title: () => tr("Rand tussen kolommen", "Border between columns"), info: () => tr("De lijnen tussen de kolommen van een venster: zijbalk, gesprek en zijpaneel.", "The lines between the columns of a window: sidebar, conversation and side panel.") },
  { id: "separator", group: "lines", cssVar: "--separator", title: () => tr("Scheiding in lijsten", "Separator in lists"), info: () => tr("Lijnen tussen items in een lijst, zoals chats en berichten.", "Lines between items in a list, such as chats and messages.") },
  { id: "fieldStroke", group: "lines", cssVar: "--field-stroke", title: () => tr("Rand van velden", "Field outline"), info: () => tr("De rand van invoervelden en de composer.", "The outline of input fields and the composer.") },
  { id: "paper", group: "text", cssVar: "--paper", title: () => tr("Tekst", "Text"), info: () => tr("Gewone tekst: titels, namen, knoppen en berichten.", "Normal text: titles, names, buttons and messages.") },
  { id: "textStrong", group: "text", cssVar: "--text-strong", title: () => tr("Sterke tekst", "Strong text"), info: () => tr("Tekst die je als geheel leest: antwoorden, documenten, bestanden en code.", "Text you read as a block: answers, documents, files and code.") },
  { id: "textSecondary", group: "text", cssVar: "--text2", title: () => tr("Secundaire tekst", "Secondary text"), info: () => tr("Ondersteunende tekst: beschrijvingen, labels en details onder een titel.", "Supporting text: descriptions, labels and details under a title.") },
  { id: "textMuted", group: "text", cssVar: "--text-muted", title: () => tr("Gedempte tekst", "Muted text"), info: () => tr("Tekst die nu minder belangrijk is, zoals puntjes tussen details en kleine labels in lijsten.", "Text that matters less right now, such as dots between details and small labels in lists.") },
  { id: "textTertiary", group: "text", cssVar: "--text3", title: () => tr("Stille tekst", "Quiet text"), info: () => tr("De stilste tekst: tijden, aantallen, hints en plaatshouders.", "The quietest text: times, counts, hints and placeholders.") },
  { id: "blue", group: "state", cssVar: "--blue", title: () => tr("Links en bezig", "Links and working"), info: () => tr("Links, en een sessie of taak die bezig is.", "Links, and a session or task that is working.") },
  { id: "mint", group: "state", cssVar: "--mint", title: () => tr("Klaar", "Done"), info: () => tr("Klaar en gelukt: een afgeronde sessie, een geslaagde check, een opgeslagen wijziging.", "Done and successful: a finished session, a passed check, a saved change.") },
  { id: "mintSoft", group: "state", cssVar: "--mint-soft", title: () => tr("Klaar, zacht", "Done, soft"), info: () => tr("Een zachter klaar, voor de rustige stemming van Nook zelf.", "A softer done, for Nook's own calm mood.") },
  { id: "amber", group: "state", cssVar: "--amber", title: () => tr("Wacht op jou", "Needs you"), info: () => tr("Wat op jou wacht: een vraag, een goedkeuring, ongelezen berichten en tellers.", "What waits on you: a question, an approval, unread messages and counts.") },
  { id: "coral", group: "state", cssVar: "--coral", title: () => tr("Fout", "Error"), info: () => tr("Fouten en mislukte runs, en knoppen die iets verwijderen.", "Errors and failed runs, and buttons that delete something.") },
  { id: "coralSoft", group: "state", cssVar: "--coral-soft", title: () => tr("Fout, zacht", "Error, soft"), info: () => tr("De tekst van een foutmelding, zachter dan Fout zodat een langere melding leesbaar blijft.", "The text of an error message, softer than Error so a longer message stays readable.") },
  { id: "violet", group: "state", cssVar: "--violet", title: () => tr("Plan en gemerged", "Plan and merged"), info: () => tr("Plannen, en pull requests die gemerged zijn.", "Plans, and pull requests that are merged.") },
  { id: "music", group: "state", cssVar: "--music", title: () => tr("Muziek", "Music"), info: () => tr("Muziek: de speler en wat er nu speelt.", "Music: the player and what is playing now.") },
  { id: "added", group: "changes", cssVar: "--added", title: () => tr("Toegevoegde regels", "Added lines"), info: () => tr("Toegevoegde regels en +-tellers in wijzigingen en diffs. Met blauw en oranje als diffkleuren wordt Links en bezig gebruikt.", "Added lines and + counts in changes and diffs. With blue and orange as diff colors, Links and working is used instead.") },
  { id: "removed", group: "changes", cssVar: "--removed", title: () => tr("Verwijderde regels", "Removed lines"), info: () => tr("Verwijderde regels en −-tellers in wijzigingen en diffs. Met blauw en oranje als diffkleuren wordt een oranje uit Wacht op jou en Fout gebruikt.", "Removed lines and − counts in changes and diffs. With blue and orange as diff colors, an orange from Needs you and Error is used instead.") },
  { id: "chatMine", group: "chat", cssVar: "--chat-mine", title: () => tr("Jouw bubbel", "Your bubble"), info: () => tr("Je eigen berichten in WhatsApp, Berichten en de andere chatapps.", "Your messages in WhatsApp, Messages and the other chat apps.") },
  { id: "chatTheirs", group: "chat", cssVar: "--chat-theirs", title: () => tr("Hun bubbel", "Their bubble"), info: () => tr("Berichten van anderen in de chatapps, en het kader rond foto's en bestanden.", "Messages from others in the chat apps, and the frame around photos and files.") },
  { id: "chatStamp", group: "chat", cssVar: "--chat-stamp", title: () => tr("Tijd en vinkjes", "Time and ticks"), info: () => tr("De tijd en de vinkjes in een chatbubbel.", "The time and the ticks inside a chat bubble.") },
  { id: "syntaxKeyword", group: "code", cssVar: "--syntax-keyword", title: () => tr("Sleutelwoord", "Keyword"), info: () => tr("Woorden van de taal in code, zoals if, func en return.", "Words of the language in code, such as if, func and return.") },
  { id: "syntaxString", group: "code", cssVar: "--syntax-string", title: () => tr("Tekenreeks", "String"), info: () => tr("Tekst tussen aanhalingstekens in code.", "Text between quotes in code.") },
  { id: "syntaxComment", group: "code", cssVar: "--syntax-comment", title: () => tr("Commentaar", "Comment"), info: () => tr("Commentaar in code.", "Comments in code.") },
  { id: "syntaxNumber", group: "code", cssVar: "--syntax-number", title: () => tr("Getal", "Number"), info: () => tr("Getallen en constanten in code.", "Numbers and constants in code.") },
  { id: "syntaxType", group: "code", cssVar: "--syntax-type", title: () => tr("Type", "Type"), info: () => tr("Namen van types en klassen in code.", "Names of types and classes in code.") },
  { id: "syntaxProperty", group: "code", cssVar: "--syntax-property", title: () => tr("Eigenschap", "Property"), info: () => tr("Eigenschappen, sleutels en functieaanroepen in code.", "Properties, keys and function calls in code.") },
  { id: "syntaxTag", group: "code", cssVar: "--syntax-tag", title: () => tr("Tag", "Tag"), info: () => tr("Tags in HTML, XML en JSX.", "Tags in HTML, XML and JSX.") },
  { id: "syntaxAttribute", group: "code", cssVar: "--syntax-attribute", title: () => tr("Attribuut", "Attribute"), info: () => tr("Attributen van tags in HTML, XML en JSX.", "Attributes of tags in HTML, XML and JSX.") },
];

export function groupTitle(group: ColorGroup): string {
  switch (group) {
    case "surfaces": return tr("Vlakken", "Surfaces");
    case "lines": return tr("Lijnen", "Lines");
    case "text": return tr("Tekst", "Text");
    case "state": return tr("Status", "Status");
    case "changes": return tr("Wijzigingen", "Changes");
    case "chat": return tr("Chats", "Chats");
    case "code": return tr("Code", "Code");
  }
}
