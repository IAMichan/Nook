# Agents koppelen aan Nook

Nook laat in de notch zien wat je AI-agents doen. Elke agent die een commando kan starten of naar een Unix-socket kan schrijven, kan zich bij Nook melden en krijgt dan een eigen regel, los van Claude Code.

Alles blijft op je Mac: berichten gaan via een lokale socket die alleen jouw gebruiker kan openen. Draait Nook niet, dan doet het hook-script niets en gaat de agent gewoon door.

## Ingebouwde koppelingen

Bij **Instellingen → Agents** koppel je deze agents met één klik. Nook laat eerst precies zien wat er verandert, maakt een backup met datum naast het bestand en schrijft pas na jouw OK. Een bestand dat Nook niet kan lezen, of dat geen geldige JSON is, blijft onaangeroerd. Een pluginbestand met dezelfde naam dat niet door Nook is gemaakt, ook.

| Agent | Bestand | Hoe | Wat je ziet |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | hooks, `--agent claude-code` | voortgang, toestemming, vragen |
| Claude (app) | zelfde hooks | herkend aan `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | voortgang, toestemming, vragen |
| Codex | `~/.codex/hooks.json` | hooks, `--agent codex` | voortgang, toestemming |
| Gemini CLI | `~/.gemini/settings.json` | hooks, `--agent gemini` | voortgang |
| Antigravity (`agy`) | `~/.gemini/config/hooks.json` | eigen groep `nook`, `--agent antigravity` | voortgang |
| Cursor | `~/.cursor/hooks.json` | hooks, `--agent cursor` | voortgang |
| Copilot CLI | `~/.copilot/hooks/nook.json` | eigen bestand, `--agent copilot` | voortgang |
| Muse Code | `~/.config/muse/settings.json` | hooks, `--agent muse` | voortgang |
| OpenCode | `~/.config/opencode/plugins/nook.js` | plugin | voortgang |
| Amp | `~/.config/amp/plugins/nook.ts` | plugin | voortgang |
| Hermes | `~/.hermes/plugins/nook/` | plugin, daarna `hermes plugins enable nook` | voortgang, "wacht op goedkeuring" |

Start de agent opnieuw na het koppelen. Toestemming geven vanuit de notch kan nu alleen bij Claude Code en Codex; bij de andere agents beslist Nook nooit iets en vraagt de agent het je zelf, zoals altijd.

## Alles vanuit de Agents-tab

In de Agents-tab bedien je je agents zonder terminal:

- **Lopende sessie**: keur goed of weiger, beantwoord meerkeuzevragen en typ een vervolgbericht. Nook zet het gesprek dan zelf voort (een sessie die nog bezig is als kopie, zodat de twee elkaar niet storen). Via ⋯ neem je de sessie helemaal over: Nook sluit het oude proces af en het gesprek gaat in de tab verder. Je kunt een sessie daar ook beëindigen.
- **Sessie die Nook alleen als proces ziet**: neem hem over in Nook of beëindig hem.
- **Eerdere sessie**: typ verder of kies Open in Nook; het gesprek gaat verder waar je bleef.
- **Nieuwe sessie**: kies + Nieuw (of Start bij een account), een map en de opdracht.

Sessies die Nook zelf draait staan onder **In Nook**, met het hele gesprek, goedkeuringen, stoppen, opnieuw proberen en per beurt de modus, rechten en het model. Dat kan bij Claude Code en Codex; andere agents kun je vanuit Nook volgen en beëindigen. Inloggen en installeren gaat nog via een Terminal-venster.

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
