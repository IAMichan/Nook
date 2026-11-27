import type { Table } from "./catalog";

// Translations for AG-131 (webhook filters, duplicate key, coalescing, deliveries log, and public webhook relay).
export const table: Table = {
  "Receive webhooks from the internet": {
    de: "Webhooks aus dem Internet empfangen",
    fr: "Recevoir des webhooks depuis Internet",
    es: "Recibir webhooks desde Internet",
  },
  "Services such as GitHub can start this computer's webhook tasks through the relay from Settings › Companion. This computer must be on and Nook open. Every request must still be signed.": {
    de: "Dienste wie GitHub können die Webhook-Aufgaben dieses Computers über das Relay aus Einstellungen › Companion starten. Dieser Computer muss eingeschaltet und Nook geöffnet sein. Jede Anfrage muss weiterhin signiert sein.",
    fr: "Des services comme GitHub peuvent lancer les tâches webhook de cet ordinateur via le relais défini dans Réglages › Companion. Cet ordinateur doit être allumé et Nook ouvert. Chaque requête doit toujours être signée.",
    es: "Servicios como GitHub pueden iniciar las tareas webhook de este equipo a través del relé de Ajustes › Companion. Este equipo debe estar encendido y Nook abierto. Cada solicitud debe seguir firmada.",
  },
  "The relay passes webhook contents readable, but keeps none of them. Companion traffic stays sealed.": {
    de: "Das Relay gibt Webhook-Inhalte lesbar weiter, speichert aber nichts. Companion-Verkehr bleibt versiegelt.",
    fr: "Le relais transmet le contenu des webhooks en clair, sans rien conserver. Le trafic du compagnon reste scellé.",
    es: "El relé transmite el contenido de los webhooks legible, pero no guarda nada. El tráfico del acompañante sigue sellado.",
  },
  "Choose a relay under Settings › Companion › Away from home first.": {
    de: "Wähle zuerst ein Relay unter Einstellungen › Companion › Unterwegs.",
    fr: "Choisissez d’abord un relais dans Réglages › Companion › Hors de chez vous.",
    es: "Elige primero un relé en Ajustes › Companion › Fuera de casa.",
  },
  "Connected to the webhook relay": {
    de: "Mit dem Webhook-Relay verbunden",
    fr: "Connecté au relais webhook",
    es: "Conectado al relé de webhooks",
  },
  "Connecting to the webhook relay…": {
    de: "Verbindung zum Webhook-Relay wird hergestellt…",
    fr: "Connexion au relais webhook…",
    es: "Conectando al relé de webhooks…",
  },
  "Webhook address (from the internet)": {
    de: "Webhook-Adresse (aus dem Internet)",
    fr: "Adresse du webhook (depuis Internet)",
    es: "Dirección del webhook (desde Internet)",
  },
  "Copy public address": {
    de: "Öffentliche Adresse kopieren",
    fr: "Copier l’adresse publique",
    es: "Copiar dirección pública",
  },
  "Filters": {
    de: "Filter",
    fr: "Filtres",
    es: "Filtros",
  },
  "The task runs only when every filter matches; other deliveries are answered, logged as filtered and start nothing. Values compare as text; an object or a list only passes “exists”. Separate the choices of “is one of” with commas.": {
    de: "Die Aufgabe läuft nur, wenn jeder Filter passt; andere Zustellungen werden beantwortet, als gefiltert protokolliert und starten nichts. Werte werden als Text verglichen; ein Objekt oder eine Liste besteht nur „existiert“. Trenne die Optionen von „ist eins von“ mit Kommas.",
    fr: "La tâche ne s’exécute que si chaque filtre correspond ; les autres livraisons reçoivent une réponse, sont journalisées comme filtrées et ne lancent rien. Les valeurs se comparent comme du texte ; un objet ou une liste ne passe que « existe ». Sépare les choix de « fait partie de » par des virgules.",
    es: "La tarea solo se ejecuta si todos los filtros coinciden; las demás entregas reciben respuesta, se registran como filtradas y no inician nada. Los valores se comparan como texto; un objeto o una lista solo pasa «existe». Separa las opciones de «es uno de» con comas.",
  },
  "Add filter": {
    de: "Filter hinzufügen",
    fr: "Ajouter un filtre",
    es: "Añadir filtro",
  },
  "Remove filter": {
    de: "Filter entfernen",
    fr: "Supprimer le filtre",
    es: "Quitar filtro",
  },
  "equals": {
    de: "ist gleich",
    fr: "est égal à",
    es: "es igual a",
  },
  "is one of": {
    de: "ist eins von",
    fr: "fait partie de",
    es: "es uno de",
  },
  "exists": {
    de: "existiert",
    fr: "existe",
    es: "existe",
  },
  "Value": {
    de: "Wert",
    fr: "Valeur",
    es: "Valor",
  },
  "Duplicate key": {
    de: "Duplikatschlüssel",
    fr: "Clé de doublon",
    es: "Clave de duplicado",
  },
  "A delivery whose key was seen in the past week is skipped. Use placeholders; when one has no value, the check is left out for that delivery. Leave empty to turn it off.": {
    de: "Eine Zustellung, deren Schlüssel in der letzten Woche schon kam, wird übersprungen. Nutze Platzhalter; fehlt einer, entfällt die Prüfung für diese Zustellung. Leer lassen schaltet sie aus.",
    fr: "Une livraison dont la clé a déjà été vue la semaine passée est ignorée. Utilise des espaces réservés ; si l’un n’a pas de valeur, la vérification ne s’applique pas à cette livraison. Laisse vide pour la désactiver.",
    es: "Una entrega cuya clave ya se vio la última semana se omite. Usa marcadores; si alguno no tiene valor, la comprobación no se aplica a esa entrega. Déjalo vacío para desactivarla.",
  },
  "Combine bursts": {
    de: "Schübe zusammenfassen",
    fr: "Regrouper les rafales",
    es: "Agrupar ráfagas",
  },
  "One run per window of": {
    de: "Ein Lauf pro Fenster von",
    fr: "Une exécution par fenêtre de",
    es: "Una ejecución por ventana de",
  },
  "seconds": {
    de: "Sekunden",
    fr: "secondes",
    es: "segundos",
  },
  "The window opens with the first delivery; deliveries that follow within it do not extend it. When it closes, one run gets the latest delivery.": {
    de: "Das Fenster öffnet sich mit der ersten Zustellung; spätere verlängern es nicht. Schließt es, bekommt ein Lauf die neueste Zustellung.",
    fr: "La fenêtre s’ouvre avec la première livraison ; les suivantes ne la prolongent pas. À sa fermeture, une seule exécution reçoit la dernière livraison.",
    es: "La ventana se abre con la primera entrega; las siguientes no la alargan. Al cerrarse, una ejecución recibe la última entrega.",
  },
  "Deliveries ({count})": {
    de: "Zustellungen ({count})",
    fr: "Livraisons ({count})",
    es: "Entregas ({count})",
  },
  "No deliveries yet.": {
    de: "Noch keine Zustellungen.",
    fr: "Aucune livraison pour l’instant.",
    es: "Todavía no hay entregas.",
  },
  "Accepted": {
    de: "Angenommen",
    fr: "Acceptée",
    es: "Aceptada",
  },
  "Filtered": {
    de: "Gefiltert",
    fr: "Filtrée",
    es: "Filtrada",
  },
  "Duplicate": {
    de: "Duplikat",
    fr: "Doublon",
    es: "Duplicada",
  },
  "Combined": {
    de: "Zusammengefasst",
    fr: "Regroupée",
    es: "Agrupada",
  },
  "Runs, or waits for the run before it": {
    de: "Läuft oder wartet auf den Lauf davor",
    fr: "S’exécute, ou attend l’exécution précédente",
    es: "Se ejecuta o espera a la ejecución anterior",
  },
  "Opened a window of {seconds} s": {
    de: "Hat ein Fenster von {seconds} s geöffnet",
    fr: "A ouvert une fenêtre de {seconds} s",
    es: "Abrió una ventana de {seconds} s",
  },
  "Failed: {filter}": {
    de: "Nicht erfüllt: {filter}",
    fr: "Non satisfait : {filter}",
    es: "No se cumple: {filter}",
  },
  "Key seen before: {key}": {
    de: "Schlüssel schon gesehen: {key}",
    fr: "Clé déjà vue : {key}",
    es: "Clave ya vista: {key}",
  },
  "{count} deliveries in this window": {
    de: "{count} Zustellungen in diesem Fenster",
    fr: "{count} livraisons dans cette fenêtre",
    es: "{count} entregas en esta ventana",
  },
  "Too many deliveries were waiting": {
    de: "Es warteten zu viele Zustellungen",
    fr: "Trop de livraisons attendaient",
    es: "Esperaban demasiadas entregas",
  },
  "Every filter needs a value name, such as body.action.": {
    de: "Jeder Filter braucht einen Wertnamen, etwa body.action.",
    fr: "Chaque filtre a besoin d’un nom de valeur, comme body.action.",
    es: "Cada filtro necesita un nombre de valor, como body.action.",
  },
};
