// Translations for CLIProxyAPI hubs (`I18n+CLIProxy.swift`, AG-48).
import type { Table } from "./catalog";

export const table: Table = {
  "CLIProxyAPI hubs": {
    de: "CLIProxyAPI-Hubs",
    fr: "Hubs CLIProxyAPI",
    es: "Hubs de CLIProxyAPI",
  },
  "A CLIProxyAPI hub pools the sign-ins of several accounts behind one address. Nook only reads what the hub itself reports: which accounts are in it, whether they take requests right now, how long a cooldown lasts and the limits the hub saw in the headers of its last requests. Nook never asks the hub to call a provider with an account's token, so no limits show until requests have gone through the hub. The management key stays in the keychain and goes only to the hub's address.": {
    de: "Ein CLIProxyAPI-Hub bündelt die Anmeldungen mehrerer Konten hinter einer Adresse. Nook liest nur, was der Hub selbst meldet: welche Konten er enthält, ob sie gerade Anfragen annehmen, wie lange eine Abkühlzeit noch dauert und die Limits, die der Hub in den Headern seiner letzten Anfragen gesehen hat. Nook bittet den Hub nie, einen Anbieter mit dem Token eines Kontos aufzurufen. Solange keine Anfragen über den Hub laufen, sind daher keine Limits zu sehen. Der Verwaltungsschlüssel bleibt im Schlüsselbund und geht nur an die Adresse des Hubs.",
    fr: "Un hub CLIProxyAPI regroupe les connexions de plusieurs comptes derrière une seule adresse. Nook lit uniquement ce que le hub signale lui-même : quels comptes il contient, s'ils acceptent des requêtes en ce moment, combien de temps dure encore un délai d'attente et les limites que le hub a vues dans les en-têtes de ses dernières requêtes. Nook ne demande jamais au hub d'appeler un fournisseur avec le jeton d'un compte. Tant qu'aucune requête ne passe par le hub, aucune limite n'apparaît donc. La clé de gestion reste dans le Trousseau et n'est envoyée qu'à l'adresse du hub.",
    es: "Un hub de CLIProxyAPI agrupa los inicios de sesión de varias cuentas tras una sola dirección. Nook solo lee lo que el propio hub informa: qué cuentas contiene, si aceptan solicitudes ahora, cuánto dura aún un enfriamiento y los límites que el hub vio en las cabeceras de sus últimas solicitudes. Nook nunca pide al hub que llame a un proveedor con el token de una cuenta, así que no se ven límites hasta que pasen solicitudes por el hub. La clave de gestión se queda en el Llavero y solo va a la dirección del hub.",
  },
  "No hub yet. Add one with its address and the management key (remote-management.secret-key) from the hub's config.": {
    de: "Noch kein Hub. Füge einen mit seiner Adresse und dem Verwaltungsschlüssel (remote-management.secret-key) aus der Konfiguration des Hubs hinzu.",
    fr: "Aucun hub pour l'instant. Ajoutez-en un avec son adresse et la clé de gestion (remote-management.secret-key) de la configuration du hub.",
    es: "Aún no hay ningún hub. Añade uno con su dirección y la clave de gestión (remote-management.secret-key) de la configuración del hub.",
  },
  "Remove hub": {
    de: "Hub entfernen",
    fr: "Supprimer le hub",
    es: "Quitar hub",
  },
  "The management key is removed from the keychain. The hub itself stays as it is.": {
    de: "Der Verwaltungsschlüssel wird aus dem Schlüsselbund entfernt. Der Hub selbst bleibt unverändert.",
    fr: "La clé de gestion est retirée du Trousseau. Le hub lui-même reste tel quel.",
    es: "La clave de gestión se elimina del Llavero. El hub en sí no cambia.",
  },
  "This hub has no accounts yet.": {
    de: "Dieser Hub hat noch keine Konten.",
    fr: "Ce hub n'a pas encore de comptes.",
    es: "Este hub aún no tiene cuentas.",
  },
  "{ok} succeeded, {fail} failed": {
    de: "{ok} erfolgreich, {fail} fehlgeschlagen",
    fr: "{ok} réussies, {fail} échouées",
    es: "{ok} correctas, {fail} fallidas",
  },
  "The hub has not seen this account's limits yet. They show up once requests go through the hub.": {
    de: "Der Hub hat die Limits dieses Kontos noch nicht gesehen. Sie erscheinen, sobald Anfragen über den Hub laufen.",
    fr: "Le hub n'a pas encore vu les limites de ce compte. Elles apparaissent dès que des requêtes passent par le hub.",
    es: "El hub aún no ha visto los límites de esta cuenta. Aparecen cuando pasan solicitudes por el hub.",
  },
  "Reading hub…": {
    de: "Hub wird gelesen…",
    fr: "Lecture du hub…",
    es: "Leyendo hub…",
  },
  "Address, for example http://127.0.0.1:8317": {
    de: "Adresse, zum Beispiel http://127.0.0.1:8317",
    fr: "Adresse, par exemple http://127.0.0.1:8317",
    es: "Dirección, por ejemplo http://127.0.0.1:8317",
  },
  "Hub address": {
    de: "Hub-Adresse",
    fr: "Adresse du hub",
    es: "Dirección del hub",
  },
  "Management key": {
    de: "Verwaltungsschlüssel",
    fr: "Clé de gestion",
    es: "Clave de gestión",
  },
  "Add hub": {
    de: "Hub hinzufügen",
    fr: "Ajouter le hub",
    es: "Añadir hub",
  },
  "Waiting {d}": {
    de: "Wartet noch {d}",
    fr: "En attente encore {d}",
    es: "En espera {d} más",
  },
  "Enter the management key, or the keychain did not keep it.": {
    de: "Gib den Verwaltungsschlüssel ein, oder der Schlüsselbund hat ihn nicht gespeichert.",
    fr: "Saisissez la clé de gestion, ou le Trousseau ne l'a pas conservée.",
    es: "Introduce la clave de gestión, o el Llavero no la guardó.",
  },
  "This is not a web address. Use http:// or https:// with the hub's host.": {
    de: "Das ist keine Webadresse. Verwende http:// oder https:// mit dem Host des Hubs.",
    fr: "Ce n'est pas une adresse web. Utilisez http:// ou https:// avec l'hôte du hub.",
    es: "Esto no es una dirección web. Usa http:// o https:// con el host del hub.",
  },
  "Use https for a hub outside this network, or the management key travels unencrypted. Plain http is fine for this computer and the local network.": {
    de: "Verwende https für einen Hub außerhalb dieses Netzwerks, sonst wird der Verwaltungsschlüssel unverschlüsselt übertragen. Einfaches http ist für diesen Computer und das lokale Netzwerk in Ordnung.",
    fr: "Utilisez https pour un hub en dehors de ce réseau, sinon la clé de gestion circule non chiffrée. Le http simple convient pour cet ordinateur et le réseau local.",
    es: "Usa https para un hub fuera de esta red, o la clave de gestión viajará sin cifrar. El http simple vale para este equipo y la red local.",
  },
  "The hub refused the management key.": {
    de: "Der Hub hat den Verwaltungsschlüssel abgelehnt.",
    fr: "Le hub a refusé la clé de gestion.",
    es: "El hub rechazó la clave de gestión.",
  },
  "The hub cannot be reached.": {
    de: "Der Hub ist nicht erreichbar.",
    fr: "Le hub est injoignable.",
    es: "No se puede llegar al hub.",
  },
  "This address does not answer like a CLIProxyAPI hub. Is management switched on in the hub's config?": {
    de: "Diese Adresse antwortet nicht wie ein CLIProxyAPI-Hub. Ist die Verwaltung in der Konfiguration des Hubs eingeschaltet?",
    fr: "Cette adresse ne répond pas comme un hub CLIProxyAPI. La gestion est-elle activée dans la configuration du hub ?",
    es: "Esta dirección no responde como un hub de CLIProxyAPI. ¿Está activada la gestión en la configuración del hub?",
  },
};
