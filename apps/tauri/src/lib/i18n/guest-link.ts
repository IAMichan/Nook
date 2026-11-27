// German, French, and Spanish translations for read-only guest links (`GuestLink` / `GuestStrip`, AG-81).
import type { Table } from "./catalog";

export const table: Table = {
  "Share with a guest": {
    de: "Mit einem Gast teilen",
    fr: "Partager avec un invité",
    es: "Compartir con un invitado",
  },
  "Copies a link that lets someone follow this session in a browser for 24 hours. What they write waits for you.": {
    de: "Kopiert einen Link, mit dem jemand diese Sitzung 24 Stunden im Browser verfolgen kann. Was er schreibt, wartet auf dich.",
    fr: "Copie un lien qui permet à quelqu’un de suivre cette session dans un navigateur pendant 24 heures. Ce qu’il écrit vous attend.",
    es: "Copia un enlace con el que alguien puede seguir esta sesión en un navegador durante 24 horas. Lo que escriba te espera.",
  },
  "Guest link copied": {
    de: "Gastlink kopiert",
    fr: "Lien invité copié",
    es: "Enlace de invitado copiado",
  },
  "Send it to one person. It works for 24 hours, while this computer is on, until you stop sharing.": {
    de: "Schick ihn an eine Person. Er funktioniert 24 Stunden, solange dieser Computer an ist, bis du das Teilen beendest.",
    fr: "Envoyez-le à une seule personne. Il fonctionne 24 heures, tant que cet ordinateur est allumé, jusqu’à ce que vous arrêtiez le partage.",
    es: "Envíalo a una sola persona. Funciona 24 horas, mientras este ordenador esté encendido, hasta que dejes de compartir.",
  },
  "Could not share this session": {
    de: "Diese Sitzung konnte nicht geteilt werden",
    fr: "Impossible de partager cette session",
    es: "No se pudo compartir esta sesión",
  },
  "Could not send the guest message": {
    de: "Die Gastnachricht konnte nicht gesendet werden",
    fr: "Impossible d’envoyer le message de l’invité",
    es: "No se pudo enviar el mensaje del invitado",
  },
  "Shared through a guest link until {time}": {
    de: "Über einen Gastlink geteilt bis {time}",
    fr: "Partagé par un lien invité jusqu’à {time}",
    es: "Compartido con un enlace de invitado hasta las {time}",
  },
  "A guest follows this session · link works until {time}": {
    de: "Ein Gast verfolgt diese Sitzung · Link gilt bis {time}",
    fr: "Un invité suit cette session · lien valable jusqu’à {time}",
    es: "Un invitado sigue esta sesión · el enlace funciona hasta las {time}",
  },
  "Guests follow this session · link works until {time} · {count} watching": {
    de: "Gäste verfolgen diese Sitzung · Link gilt bis {time} · {count} schauen zu",
    fr: "Des invités suivent cette session · lien valable jusqu’à {time} · {count} regardent",
    es: "Invitados siguen esta sesión · el enlace funciona hasta las {time} · {count} mirando",
  },
  "Stop sharing": {
    de: "Teilen beenden",
    fr: "Arrêter le partage",
    es: "Dejar de compartir",
  },
  "A guest wrote": {
    de: "Ein Gast schrieb",
    fr: "Un invité a écrit",
    es: "Un invitado escribió",
  },
  "Guest link": {
    de: "Gastlink",
    fr: "Lien invité",
    es: "Enlace de invitado",
  },
};
