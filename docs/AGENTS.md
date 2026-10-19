# Agents koppelen aan Nook

Nook laat in de notch zien wat je AI-agents doen. Elke agent die een commando kan starten of naar een Unix-socket kan schrijven, kan zich bij Nook melden en krijgt dan een eigen regel, los van Claude Code.

Alles blijft op je Mac: berichten gaan via een lokale socket die alleen jouw gebruiker kan openen. Draait Nook niet, dan doet het hook-script niets en gaat de agent gewoon door.

## Ingebouwde koppelingen

Bij **Instellingen › Agents** koppel je deze agents met één klik. Nook laat eerst precies zien wat er verandert, maakt een backup met datum naast het bestand en schrijft pas na jouw OK. Een bestand dat Nook niet kan lezen, of dat geen geldige JSON is, blijft onaangeroerd. Een pluginbestand met dezelfde naam dat niet door Nook is gemaakt, ook.

| Agent | Bestand | Hoe | Wat je ziet |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | hooks, `--agent claude-code` | voortgang, toestemming, vragen |
| Claude (app) | zelfde hooks | herkend aan `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | voortgang, toestemming, vragen |
| Codex | `~/.codex/hooks.json` | hooks, `--agent codex` | voortgang, toestemming |
| Gemini CLI | `~/.gemini/settings.json` | hooks, `--agent gemini` | voortgang |
| Antigravity (`agy`) | `~/.gemini/config/hooks.json` | eigen groep `nook`, `--agent antigravity`, pad zonder spaties via `~/.nook/nook-hook`, geen `PreToolUse` | voortgang |
| Cursor | `~/.cursor/hooks.json` | hooks, `--agent cursor` | voortgang |
| Copilot CLI | `~/.copilot/hooks/nook.json` | eigen bestand, `--agent copilot` | voortgang |
| Muse Code | `~/.config/muse/settings.json` | hooks, `--agent muse` | voortgang |
| OpenCode | `~/.config/opencode/plugins/nook.js` | plugin | voortgang |
| Amp | `~/.config/amp/plugins/nook.ts` | plugin | voortgang |
| Hermes | `~/.hermes/plugins/nook/` | plugin, daarna `hermes plugins enable nook` | voortgang, "wacht op goedkeuring" |

Start de agent opnieuw na het koppelen. Toestemming geven vanuit de notch kan nu alleen bij Claude Code en Codex; bij de andere agents beslist Nook nooit iets en vraagt de agent het je zelf, zoals altijd.

## Je agents bedienen

Sluit je Nook en open je hem weer, dan zijn de agents die in je terminal doorliepen er direct weer: Nook bewaart de sessies die hij via hooks kende (`agent-sessions.json`) en zet ze terug. Een sessie waarvan het proces intussen weg is, laat Nook bij de eerste scan los.

Er is één lijst van agentsessies (`AgentSessionRegistry`). Hooks, het proces-overzicht, transcripten en sessies die Nook zelf draait komen samen: een gesprek staat er één keer in, ook als het uit meerdere bronnen bekend is, en twee processen in dezelfde map blijven twee rijen. Processen die Nook zelf startte (herkend aan `NOOK_RUN_ID` of `NOOK_INTERNAL` in hun omgeving) staan er niet in en worden nooit beëindigd.

**In de notch** (tab Agents, compact) zie je wat loopt en wat op je wacht, keur je goed, beantwoord je meerkeuzevragen en typ je een kort vervolg. Een nieuwe sessie starten en accounts beheren gaat niet meer hier: **Nieuwe sessie** opent het venster, accounts staan bij Instellingen.

**In het hoofdvenster** (⌥⌘W › Agents) heb je de volledige weergave: het gesprek, goedkeuringen, stoppen, hervatten, opnieuw proberen en per beurt de modus, rechten en het model. Rechts staan branch, worktree, wijzigingen met diff, **Commit**, **Push** en een pull request.

- **Goedkeuringen** zijn overal hetzelfde (`ApprovalCenter`, `ApprovalView`): het hele commando of de hele wijziging, het risico, en **Toestaan**, **Altijd**, **Weigeren** en **In terminal**. Een goedkeuring die in het venster is afgehandeld, verdwijnt direct uit de notch.
- **Lopende sessie**: een sessie die nog bezig is, zet Nook voort als kopie (`--fork-session`), zodat twee schrijvers elkaar niet storen. Via ⋯ neem je een sessie helemaal over; Nook sluit het oude proces af en het gesprek gaat verder.
- **Sessie die Nook alleen als proces ziet**: neem hem over in Nook of beëindig hem.
- **Eerdere sessie**: kies Open in Nook; het gesprek gaat verder waar je bleef.
- **Open terminal hier** opent de ingebouwde terminal in de map van de sessie.
- **Limieten** per account (5 uur en week) staan bij Instellingen › Gebruik (`QuotaService`); Codex wordt per accountmap gelezen.

Sessies die Nook zelf draait staan onder **In Nook**. Dat kan bij Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Grok en Antigravity, elk met één verbinding per sessie zoals T3Code: Codex via `codex app-server`, Claude Code als één proces dat tussen beurten blijft wachten, en de rest via ACP (Antigravity op Google's ACP-server, die Nook eenmalig installeert). Goedkeuringen en vragen beantwoord je in Nook; Codex en Claude Code kun je tijdens een beurt bijsturen; bij een sessie in een eigen worktree kun je de bestanden terugzetten naar vóór een bericht. Een nieuwe sessie krijgt vanzelf een korte titel, één git-knop doet commit, push en pull request (de agent schrijft de teksten), en een sessie die op een gebruikslimiet stuit kan vanzelf verdergaan zodra die vrij is. Gesprekken uit de Antigravity-app beantwoord je via zijn agent-API; andere agents kun je vanuit Nook volgen en beëindigen. Zie [AGENTS-T3CODE.md](AGENTS-T3CODE.md).

**Het hele gesprek.** Bij elke sessie, lopend of eerder, zie je het volledige gesprek uit het transcript van de agent, met zijn denkstappen ingeklapt ertussen: Claude Code, Codex (de redeneersamenvattingen), Gemini CLI (`thoughts`) en Antigravity. Neem je een sessie over, dan neemt Nook dat hele gesprek mee.

**Alleen wat gekoppeld is.** Bij een nieuwe sessie, in de lijst met eerdere sessies en bij Gebruik zie je alleen agents en accounts die ingelogd zijn op een geïnstalleerde agent. De modellen zijn die de agent zelf aanbiedt (Codex `model/list`, de ACP-agents bij een sessie), anders de bekende, plus de modellen die je recent met die agent gebruikte. Inloggen en installeren gaat in de ingebouwde terminal (of Terminal.app, naar keuze bij Instellingen › Agents); Nook ziet het inloggen vanzelf doordat het regelmatig controleert of het account bekend is.

## De werkruimte van Nook voor je agents

Agents kunnen ook zelf Nooks werkruimte gebruiken: een commando starten in een zichtbare terminal van Nook (zoals een dev-server), een pagina openen en controleren in Nooks browser (tekst, console-fouten, screenshot) en een pull request voorstellen dat jij in de notch goedkeurt. Dat gaat via een kleine MCP-server, `~/.nook/nook-mcp`. Sessies die Nook start (Claude Code en Codex) krijgen hem vanzelf; een agent die je zelf start koppel je bij **Instellingen › Agents › Werkruimte**. Lezen gaat direct, een commando dat niet duidelijk onschuldig is en elk pull request vragen eerst jouw OK, gevaarlijke commando's weigert Nook altijd. Zie [WERKRUIMTE-AGENTS.md](WERKRUIMTE-AGENTS.md).

## Zelf een agent koppelen

### Via het hook-script (aanrader)

Het hook-script staat op:

```
~/Library/Application Support/Nook/nook-hook.sh
```

Laat je agent het bij elke gebeurtenis starten, met de JSON van de gebeurtenis op stdin:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "\"$HOME/Library/Application Support/Nook/nook-hook.sh\" --agent mijn-tool" }
    ]
  }
}
```

- `--agent <naam>`: de naam waaronder de agent in Nook staat. Gebruik kleine letters, cijfers, `-` en `_` (maximaal 32 tekens). Bekende namen krijgen een nette weergavenaam (zie hieronder); een andere naam verschijnt met een hoofdletter, zoals `Mijn-tool`.
- `<Gebeurtenis>` (optioneel): de naam van de gebeurtenis, voor agents die die niet zelf in de JSON zetten, bijvoorbeeld `--agent mijn-tool Stop`. Staat `hook_event_name` wel in de JSON, dan telt die.

### Het veld `nook_agent`

Kun je geen argumenten meegeven, zet dan de naam in de JSON zelf:

```json
{ "hook_event_name": "UserPromptSubmit", "session_id": "s1", "nook_agent": "mijn-tool", "prompt": "Schrijf de tests" }
```

Het script neemt `nook_agent` over als er geen `--agent` is meegegeven (`--agent` wint altijd). Een ongeldige naam telt niet; de gebeurtenis komt dan bij Claude Code terecht.

### Rechtstreeks via de socket

Wie liever zelf schrijft: stuur één regel JSON, afgesloten met een newline, naar

```
~/Library/Application Support/Nook/hub.sock
```

```json
{"agent":"mijn-tool","mode":"event","event":{"hook_event_name":"Stop","session_id":"s1","cwd":"/Users/jij/project"}}
```

`mode` is `event` voor gewone meldingen. Nook sluit de verbinding als hij klaar is; wacht dus niet op een antwoord.

## Gebeurtenissen

Nook gebruikt de namen van Claude Code. Veelgebruikte namen van andere agents (`BeforeTool`, `preToolUse`, `beforeSubmitPrompt`, `PreInvocation`, `session_start`, …) zet Nook zelf om.

| Gebeurtenis | Wat Nook doet |
|---|---|
| `SessionStart` | zet de agent op "bezig" |
| `UserPromptSubmit` | nieuwe opdracht; `prompt` verschijnt als stap |
| `PreToolUse` | nieuwe stap met wat de tool doet (`tool_name`, `tool_input`) |
| `PostToolUse` / `PostToolUseFailure` | sluit de laatste stap af als klaar of mislukt |
| `Notification` | de agent wacht op je; `message` verschijnt in de notch |
| `Stop` | klaar; `last_assistant_message` wordt de samenvatting |
| `StopFailure` | gestopt met een fout (`error`) |
| `SubagentStart` / `SubagentStop` | hulpagent gestart of klaar |
| `SessionEnd` | de agent verdwijnt uit de lijst |

Velden die Nook leest: `session_id` (anders `conversation_id`, `conversationId`, `sessionId` of `thread_id`), `cwd` (anders `workdir`, `workspacePaths[0]` of `workspace_roots[0]`), `tool_name` (anders `toolName` of `toolCall.name`), `tool_input` (anders `toolArgs` of `toolCall.args`), `prompt`, `message`, `last_assistant_message` en `error`. Een `stop` met `"status": "error"` telt als `StopFailure`.

Ziet je agent alleen dat een tool klaar is, stuur dan `PostToolUse` met `"nook_show_step": true`: het script laat de stap dan eerst zien en sluit hem meteen af.

## Weergavenamen

`claude-code` → Claude Code, `claude-desktop` → Claude (app), `codex` → Codex, `gemini` → Gemini CLI, `antigravity` → Antigravity, `copilot` → Copilot CLI, `cursor` → Cursor, `opencode` → OpenCode, `amp` → Amp, `hermes` → Hermes, `muse` → Muse Code, `qwen` → Qwen Code.

## Snel proberen

Met Nook aan:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hallo","nook_agent":"demo"}' \
  | ~/Library/Application\ Support/Nook/nook-hook.sh
```

In de notch staat nu "Demo" met de opdracht "hallo".
