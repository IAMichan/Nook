# Beveiliging

Nook heeft toegang tot je scherm, agenda, microfoon en de shell-hooks van je coding agents. Beveiligingsproblemen nemen we dus serieus.

## Een probleem melden

Meld kwetsbaarheden **niet** in een openbaar issue. Gebruik in plaats daarvan [GitHub private vulnerability reporting](https://github.com/IAMichan/nook/security/advisories/new).

Vermeld als het kan:
- wat er mis is en welke impact het heeft;
- hoe je het kunt reproduceren;
- de versie of commit.

Je krijgt binnen een week een eerste reactie.

## Waar het vooral om gaat

- Prompt-injectie via schermtekst, agenda-items of tool-uitkomsten die tot een actie leidt zonder bevestiging door de gebruiker.
- Toegang tot de hook-socket door een andere gebruiker of een ander proces.
- Uitlekken van de API-sleutel of van lokale gegevens (`nook.sqlite`).
- Riskante shell-commando's die door `CommandRisk` heen glippen.

## Ondersteunde versies

Alleen de nieuwste versie op `main` krijgt beveiligingsupdates.
