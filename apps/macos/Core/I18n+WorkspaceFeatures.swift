import Foundation

// Texts for the workspace features: per-project defaults (Settings › Workspace), the "Coding agents" setup step,
// sending one prompt to several models, fork lineage, and syntax colors in diffs.
// Numbers use %ld, text uses %@.

let workspaceFeatureTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "settings.scope.title": "Geldt voor",
        "settings.scope.global": "Alle projecten",
        "settings.scope.footer": "Nieuwe sessies in dit project beginnen met deze waarden. Een waarde met Overgenomen volgt de instelling voor alle projecten; verander hem om dit project een eigen waarde te geven.",
        "settings.scope.inherited": "Overgenomen",
        "settings.scope.inheritedHelp": "Volgt de instelling voor alle projecten",
        "settings.scope.reset": "Gebruik de instelling voor alle projecten",
    ],
    .en: [
        "settings.scope.title": "Applies to",
        "settings.scope.global": "All projects",
        "settings.scope.footer": "New sessions in this project start with these values. A value marked Inherited follows the setting for all projects; change it to give this project its own.",
        "settings.scope.inherited": "Inherited",
        "settings.scope.inheritedHelp": "Follows the setting for all projects",
        "settings.scope.reset": "Use the setting for all projects",
    ],
    .de: [
        "settings.scope.title": "Gilt für",
        "settings.scope.global": "Alle Projekte",
        "settings.scope.footer": "Neue Sitzungen in diesem Projekt starten mit diesen Werten. Ein Wert mit Übernommen folgt der Einstellung für alle Projekte; ändere ihn, um diesem Projekt einen eigenen zu geben.",
        "settings.scope.inherited": "Übernommen",
        "settings.scope.inheritedHelp": "Folgt der Einstellung für alle Projekte",
        "settings.scope.reset": "Einstellung für alle Projekte verwenden",
    ],
    .fr: [
        "settings.scope.title": "S'applique à",
        "settings.scope.global": "Tous les projets",
        "settings.scope.footer": "Les nouvelles sessions de ce projet démarrent avec ces valeurs. Une valeur marquée Hérité suit le réglage de tous les projets ; modifiez-la pour donner à ce projet la sienne.",
        "settings.scope.inherited": "Hérité",
        "settings.scope.inheritedHelp": "Suit le réglage de tous les projets",
        "settings.scope.reset": "Utiliser le réglage de tous les projets",
    ],
    .es: [
        "settings.scope.title": "Se aplica a",
        "settings.scope.global": "Todos los proyectos",
        "settings.scope.footer": "Las sesiones nuevas de este proyecto empiezan con estos valores. Un valor marcado como Heredado sigue el ajuste de todos los proyectos; cámbialo para dar a este proyecto el suyo.",
        "settings.scope.inherited": "Heredado",
        "settings.scope.inheritedHelp": "Sigue el ajuste de todos los proyectos",
        "settings.scope.reset": "Usar el ajuste de todos los proyectos",
    ],
]
