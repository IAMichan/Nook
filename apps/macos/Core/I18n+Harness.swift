import Foundation

// Texts of what Nook learned from Code: opening files and links where they point, the file menu, the browser,
// quitting with sessions at work, commit styles, remote machines and the companion.

let harnessTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "ws.file.missing": "%@ bestaat niet meer.",
        "ws.file.copyPath": "Kopieer pad",
        "ws.file.copyRelative": "Kopieer pad in repository",
        "ws.browser.crashed": "De pagina werkt niet meer. Laad hem opnieuw om het nog eens te proberen.",
    ],
    .en: [
        "ws.file.missing": "%@ is no longer there.",
        "ws.file.copyPath": "Copy path",
        "ws.file.copyRelative": "Copy path in repository",
        "ws.browser.crashed": "The page stopped working. Reload it to try again.",
    ],
    .de: [
        "ws.file.missing": "%@ gibt es nicht mehr.",
        "ws.file.copyPath": "Pfad kopieren",
        "ws.file.copyRelative": "Pfad im Repository kopieren",
        "ws.browser.crashed": "Die Seite funktioniert nicht mehr. Lade sie neu, um es noch einmal zu versuchen.",
    ],
    .fr: [
        "ws.file.missing": "%@ n'existe plus.",
        "ws.file.copyPath": "Copier le chemin",
        "ws.file.copyRelative": "Copier le chemin dans le dépôt",
        "ws.browser.crashed": "La page a cessé de fonctionner. Rechargez-la pour réessayer.",
    ],
    .es: [
        "ws.file.missing": "%@ ya no existe.",
        "ws.file.copyPath": "Copiar ruta",
        "ws.file.copyRelative": "Copiar ruta en el repositorio",
        "ws.browser.crashed": "La página dejó de funcionar. Vuelve a cargarla para intentarlo de nuevo.",
    ],
]
