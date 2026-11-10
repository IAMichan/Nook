import Foundation

// Texts for how a session's conversation draws an answer and its work (code block actions, folded passages, table copy)
// and what sits around the composer. One block per language; every key in all five.

let transcriptTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "code.wrap": "Regels laten teruglopen",
        "code.noWrap": "Regels niet laten teruglopen",
        "code.runInTerminal": "Uitvoeren in terminal",
        "markdown.details": "Details",
        "table.copy": "Tabel kopiëren",
        "table.copyMarkdown": "Kopiëren als Markdown",
        "table.copyCSV": "Kopiëren als CSV",
    ],
    .en: [
        "code.wrap": "Wrap lines",
        "code.noWrap": "Don't wrap lines",
        "code.runInTerminal": "Run in terminal",
        "markdown.details": "Details",
        "table.copy": "Copy table",
        "table.copyMarkdown": "Copy as Markdown",
        "table.copyCSV": "Copy as CSV",
    ],
    .de: [
        "code.wrap": "Zeilen umbrechen",
        "code.noWrap": "Zeilen nicht umbrechen",
        "code.runInTerminal": "Im Terminal ausführen",
        "markdown.details": "Details",
        "table.copy": "Tabelle kopieren",
        "table.copyMarkdown": "Als Markdown kopieren",
        "table.copyCSV": "Als CSV kopieren",
    ],
    .fr: [
        "code.wrap": "Renvoyer les lignes à la ligne",
        "code.noWrap": "Ne pas renvoyer à la ligne",
        "code.runInTerminal": "Exécuter dans le terminal",
        "markdown.details": "Détails",
        "table.copy": "Copier le tableau",
        "table.copyMarkdown": "Copier en Markdown",
        "table.copyCSV": "Copier en CSV",
    ],
    .es: [
        "code.wrap": "Ajustar líneas",
        "code.noWrap": "No ajustar líneas",
        "code.runInTerminal": "Ejecutar en el terminal",
        "markdown.details": "Detalles",
        "table.copy": "Copiar tabla",
        "table.copyMarkdown": "Copiar como Markdown",
        "table.copyCSV": "Copiar como CSV",
    ],
]
