import type { Table } from "./catalog";

// Translations for deploying the user's own companion relay on Cloudflare (`OwnRelaySheet` /
// `CloudflareRelayDeployer`, CO-08), matching macOS `I18n+SettingsFlowsC.swift` and `I18n+Workspace.swift`.
export const table: Table = {
  "Your own relay": {
    de: "Dein eigenes Relay",
    fr: "Votre propre relais",
    es: "Tu propio relé",
  },
  "Your own relay runs on a free Cloudflare account. Nook puts it there for you with one Cloudflare token.": {
    de: "Dein eigenes Relay läuft auf einem kostenlosen Cloudflare-Konto. Nook richtet es dort mit einem Cloudflare-Token für dich ein.",
    fr: "Votre propre relais tourne sur un compte Cloudflare gratuit. Nook l’y installe pour vous avec un jeton Cloudflare.",
    es: "Tu propio relé funciona en una cuenta gratuita de Cloudflare. Nook lo instala ahí por ti con un token de Cloudflare.",
  },
  "Make a token at Cloudflare": {
    de: "Erstelle ein Token bei Cloudflare",
    fr: "Créez un jeton chez Cloudflare",
    es: "Crea un token en Cloudflare",
  },
  "Sign in (or create a free account) and create the token that is filled in for you, or pick the template “Edit Cloudflare Workers”.": {
    de: "Melde dich an (oder erstelle ein kostenloses Konto) und erstelle das bereits ausgefüllte Token, oder wähle die Vorlage „Edit Cloudflare Workers“.",
    fr: "Connectez-vous (ou créez un compte gratuit) et créez le jeton déjà prérempli, ou choisissez le modèle « Edit Cloudflare Workers ».",
    es: "Inicia sesión (o crea una cuenta gratuita) y crea el token que ya viene rellenado, o elige la plantilla «Edit Cloudflare Workers».",
  },
  "Open Cloudflare": {
    de: "Cloudflare öffnen",
    fr: "Ouvrir Cloudflare",
    es: "Abrir Cloudflare",
  },
  "Paste the token": {
    de: "Token einfügen",
    fr: "Collez le jeton",
    es: "Pega el token",
  },
  "Set up the relay": {
    de: "Relay einrichten",
    fr: "Configurer le relais",
    es: "Configurar el relé",
  },
  "Nook puts the relay on your Cloudflare account and checks that this computer connects to it.": {
    de: "Nook legt das Relay auf dein Cloudflare-Konto und prüft, ob dieser Computer sich damit verbindet.",
    fr: "Nook installe le relais sur votre compte Cloudflare et vérifie que cet ordinateur s’y connecte.",
    es: "Nook pone el relé en tu cuenta de Cloudflare y comprueba que este equipo se conecta a él.",
  },
  "Finding your Cloudflare account…": {
    de: "Dein Cloudflare-Konto wird gesucht…",
    fr: "Recherche de votre compte Cloudflare…",
    es: "Buscando tu cuenta de Cloudflare…",
  },
  "Putting the relay on your account…": {
    de: "Das Relay wird auf dein Konto gelegt…",
    fr: "Déploiement du relais sur votre compte…",
    es: "Instalando el relé en tu cuenta…",
  },
  "Starting the relay…": {
    de: "Das Relay wird gestartet…",
    fr: "Démarrage du relais…",
    es: "Iniciando el relé…",
  },
  "Setting up did not work: {message}": {
    de: "Einrichten hat nicht geklappt: {message}",
    fr: "La configuration a échoué : {message}",
    es: "La configuración no funcionó: {message}",
  },
  "I already have a relay": {
    de: "Ich habe schon ein Relay",
    fr: "J’ai déjà un relais",
    es: "Ya tengo un relé",
  },
  "Your relay: {address}": {
    de: "Dein Relay: {address}",
    fr: "Votre relais : {address}",
    es: "Tu relé: {address}",
  },
  "Set up again": {
    de: "Neu einrichten",
    fr: "Configurer à nouveau",
    es: "Configurar de nuevo",
  },
  "Cloudflare did not accept this token. Copy it again, or create a new one with Open Cloudflare.": {
    de: "Cloudflare hat dieses Token nicht akzeptiert. Kopiere es erneut oder erstelle ein neues über Cloudflare öffnen.",
    fr: "Cloudflare n’a pas accepté ce jeton. Copiez-le à nouveau ou créez-en un nouveau via Ouvrir Cloudflare.",
    es: "Cloudflare no aceptó este token. Cópialo de nuevo o crea uno nuevo con Abrir Cloudflare.",
  },
  "The token cannot see a Cloudflare account. Create it with the permissions Open Cloudflare fills in.": {
    de: "Das Token sieht kein Cloudflare-Konto. Erstelle es mit den Rechten, die Cloudflare öffnen ausfüllt.",
    fr: "Le jeton ne voit aucun compte Cloudflare. Créez-le avec les autorisations préremplies par Ouvrir Cloudflare.",
    es: "El token no ve ninguna cuenta de Cloudflare. Créalo con los permisos que rellena Abrir Cloudflare.",
  },
  "This token can see several Cloudflare accounts. Create it for one account (Account Resources › Include › that account) and paste it again.": {
    de: "Dieses Token sieht mehrere Cloudflare-Konten. Erstelle es für ein Konto (Account Resources › Include › dieses Konto) und füge es erneut ein.",
    fr: "Ce jeton voit plusieurs comptes Cloudflare. Créez-le pour un seul compte (Account Resources › Include › ce compte) et collez-le à nouveau.",
    es: "Este token ve varias cuentas de Cloudflare. Créalo para una sola cuenta (Account Resources › Include › esa cuenta) y pégalo de nuevo.",
  },
  "Cloudflare did not give your account a workers.dev address.": {
    de: "Cloudflare hat deinem Konto keine workers.dev-Adresse gegeben.",
    fr: "Cloudflare n’a pas attribué d’adresse workers.dev à votre compte.",
    es: "Cloudflare no dio una dirección workers.dev a tu cuenta.",
  },
  "The relay is set up but does not answer yet. Try again in a minute.": {
    de: "Das Relay ist eingerichtet, antwortet aber noch nicht. Versuche es in einer Minute erneut.",
    fr: "Le relais est configuré mais ne répond pas encore. Réessayez dans une minute.",
    es: "El relé está configurado pero aún no responde. Inténtalo de nuevo en un minuto.",
  },
  "No Tailscale and no port opened on your router: this computer calls out to the relay and your phone meets it there. Everything stays encrypted with the pairing key; the relay only sees when and how much goes through.": {
    de: "Ohne Tailscale und ohne Portfreigabe im Router: Dieser Computer ruft das Relay selbst an und dein Telefon trifft ihn dort. Alles bleibt mit dem Kopplungsschlüssel verschlüsselt; das Relay sieht nur, wann und wie viel durchgeht.",
    fr: "Sans Tailscale et sans port ouvert sur votre routeur : cet ordinateur appelle lui-même le relais et votre téléphone l’y retrouve. Tout reste chiffré avec la clé d’appairage ; le relais voit seulement quand et combien de données passent.",
    es: "Sin Tailscale y sin abrir puertos en tu router: este equipo llama al relé y tu teléfono se encuentra con él allí. Todo sigue cifrado con la clave de enlace; el relé solo ve cuándo y cuánto pasa.",
  },
};
