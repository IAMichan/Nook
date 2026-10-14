import Foundation

/// Kleine plugins voor agents die geen hook-commando's draaien maar zelf code laden (OpenCode, Amp, Hermes).
/// Elke plugin start Nooks hook-script met `--agent <naam>` en geeft het één regel JSON; de agent wacht er nooit op.
/// Draait Nook niet, dan gebeurt er niets. Een plugin beslist nooit iets voor de agent (geen toestemming).
/// Elk bestand zegt dat Nook het maakte: alleen zo'n bestand werkt Nook bij of haalt het weg.
enum AgentPlugins {
    /// Staat in elk bestand dat Nook schrijft; het pad van het hook-script (nook-hook.sh) staat er ook in.
    static let marker = "nook-hook"

    /// Het pad naar het hook-script als tekst die in JavaScript, TypeScript en Python hetzelfde betekent.
    static var hookLiteral: String {
        literal(NookPaths.hookScriptURL.path)
    }

    /// Een JSON-tekenreeks is ook een geldige tekenreeks in JavaScript, TypeScript en Python.
    static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    // Andere tekens blijven gewoon staan: alle drie de talen lezen UTF-8.
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: OpenCode

    /// ~/.config/opencode/plugins/nook.js
    static var openCode: String {
        #"""
        // Nook-plugin voor OpenCode: gemaakt door Nook (nook-hook). Nook werkt dit bestand zelf bij of haalt het weg.
        // Stuurt door wat OpenCode doet naar de notch. OpenCode wacht er nooit op en als Nook niet draait, gebeurt er niets.
        import { spawn } from 'node:child_process';

        const HOOK = \#(hookLiteral);
        const EVENTS = {
          'session.created': 'SessionStart',
          'session.idle': 'Stop',
          'session.error': 'StopFailure',
          'session.deleted': 'SessionEnd',
        };
        const TOOLS = { bash: 'Bash', edit: 'Edit', write: 'Write', read: 'Read', grep: 'Grep', glob: 'Glob', webfetch: 'WebFetch', task: 'Task' };

        function forward(hook_event_name, fields) {
          try {
            const p = spawn(HOOK, ['--agent', 'opencode'], { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
            p.on('error', () => {});
            p.stdin.on('error', () => {});
            p.stdin.end(JSON.stringify({ hook_event_name, ...fields }) + '\n');
            p.unref();
          } catch {}
        }

        function toolName(tool) {
          if (typeof tool !== 'string') return '';
          return TOOLS[tool] || tool;
        }

        // OpenCode schrijft filePath en oldString; Nook leest de namen van Claude Code.
        function toolInput(args) {
          if (!args || typeof args !== 'object') return {};
          const input = { ...args };
          if (args.filePath !== undefined && input.file_path === undefined) input.file_path = args.filePath;
          if (args.oldString !== undefined && input.old_string === undefined) input.old_string = args.oldString;
          if (args.newString !== undefined && input.new_string === undefined) input.new_string = args.newString;
          return input;
        }

        export const NookPlugin = async ({ directory } = {}) => ({
          event: async ({ event }) => {
            const name = EVENTS[event?.type];
            if (!name) return;
            const props = event.properties || {};
            forward(name, { session_id: props.sessionID || props.info?.id || '', cwd: directory || '' });
          },
          'chat.message': async (input, output) => {
            const parts = Array.isArray(output?.parts) ? output.parts : [];
            const prompt = parts.filter((p) => p && p.type === 'text' && typeof p.text === 'string').map((p) => p.text).join('\n');
            forward('UserPromptSubmit', { session_id: input?.sessionID || '', cwd: directory || '', prompt });
          },
          'tool.execute.before': async (input, output) => {
            forward('PreToolUse', {
              session_id: input?.sessionID || '',
              cwd: directory || '',
              tool_name: toolName(input?.tool),
              tool_input: toolInput(output?.args),
            });
          },
          'tool.execute.after': async (input) => {
            forward('PostToolUse', {
              session_id: input?.sessionID || '',
              cwd: directory || '',
              tool_name: toolName(input?.tool),
            });
          },
        });

        """#
    }

    // MARK: Amp

    /// ~/.config/amp/plugins/nook.ts
    static var amp: String {
        #"""
        // Nook-plugin voor Amp: gemaakt door Nook (nook-hook). Nook werkt dit bestand zelf bij of haalt het weg.
        // Alleen om te laten zien: Amp wacht er nooit op en de plugin beslist niets voor Amp.
        import { spawn } from 'node:child_process';

        const HOOK = \#(hookLiteral);

        function forward(hook_event_name: string, fields: Record<string, unknown>): void {
          try {
            const p = spawn(HOOK, ['--agent', 'amp'], { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
            p.on('error', () => {});
            p.stdin?.on('error', () => {});
            p.stdin?.end(JSON.stringify({ hook_event_name, ...fields }) + '\n');
            p.unref();
          } catch {}
        }

        export default function (amp: any): void {
          const base = (e: any) => ({ session_id: e?.thread?.id ?? '', cwd: process.cwd() });
          amp.on('session.start', (e: any) => { forward('SessionStart', base(e)); });
          amp.on('agent.start', (e: any) => {
            forward('UserPromptSubmit', { ...base(e), prompt: typeof e?.message === 'string' ? e.message : '' });
          });
          // Een stap per tool zodra die klaar is: naar tool.call luisteren zou betekenen dat de plugin
          // een oordeel voor Amp moet geven, en dat doet Nook nooit. nook_show_step toont de stap en sluit hem meteen af.
          amp.on('tool.result', (e: any) => {
            forward('PostToolUse', {
              ...base(e),
              tool_name: typeof e?.tool === 'string' ? e.tool : '',
              tool_input: e?.input && typeof e.input === 'object' ? e.input : {},
              nook_show_step: true,
            });
          });
          amp.on('agent.end', (e: any) => { forward('Stop', { ...base(e), status: e?.status ?? '' }); });
        }

        """#
    }

    // MARK: Hermes

    /// ~/.hermes/plugins/nook/__init__.py
    static var hermesInit: String {
        #"""
        # Nook-plugin voor Hermes Agent: gemaakt door Nook (nook-hook). Nook werkt dit bestand zelf bij of haalt het weg.
        # Sessies en tools gaan naar de notch, zonder te wachten: Hermes houdt elke goedkeuring zelf in handen.
        import json, os, subprocess, threading

        HOOK = \#(hookLiteral)
        _current_session_id = ''


        def _fire(fields):
            # Start het hook-script en ga meteen door; een thread ruimt het proces op.
            def _run():
                try:
                    fields.setdefault('cwd', os.getcwd())
                    p = subprocess.Popen([HOOK, '--agent', 'hermes'], stdin=subprocess.PIPE,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         start_new_session=True)
                    p.stdin.write(json.dumps(fields).encode() + b'\n')
                    p.stdin.close()
                    p.wait(timeout=5)
                except Exception:
                    pass
            threading.Thread(target=_run, daemon=True).start()


        def _session(kwargs, key='session_id'):
            return kwargs.get(key, '') or _current_session_id


        def register(ctx):
            def on_session_start(**kwargs):
                global _current_session_id
                _current_session_id = kwargs.get('session_id', '')
                _fire({'hook_event_name': 'SessionStart', 'session_id': _current_session_id,
                       'platform': kwargs.get('platform', 'cli') or 'cli'})

            def on_session_end(**kwargs):
                # Stop komt van post_llm_call, met het laatste antwoord erbij.
                if kwargs.get('interrupted'):
                    _fire({'hook_event_name': 'StopFailure', 'session_id': _session(kwargs),
                           'error': 'onderbroken'})

            def post_llm_call(**kwargs):
                _fire({'hook_event_name': 'Stop', 'session_id': _session(kwargs),
                       'last_assistant_message': kwargs.get('assistant_response', '') or ''})

            def pre_tool_call(**kwargs):
                args = kwargs.get('args')
                _fire({'hook_event_name': 'PreToolUse', 'session_id': _session(kwargs),
                       'tool_name': kwargs.get('tool_name', ''),
                       'tool_input': args if isinstance(args, dict) else {}})

            def post_tool_call(**kwargs):
                _fire({'hook_event_name': 'PostToolUse', 'session_id': _session(kwargs),
                       'tool_name': kwargs.get('tool_name', '')})

            def pre_approval_request(**kwargs):
                # Alleen kijken: Hermes vraagt en beslist zelf; de notch laat zien dat hij op je wacht.
                command = kwargs.get('command', '') or kwargs.get('description', '')
                _fire({'hook_event_name': 'Notification', 'session_id': _session(kwargs, 'session_key'),
                       'message': ('Hermes wacht op je goedkeuring: ' + command) if command
                                  else 'Hermes wacht op je goedkeuring'})

            ctx.register_hook('on_session_start', on_session_start)
            ctx.register_hook('on_session_end', on_session_end)
            ctx.register_hook('post_llm_call', post_llm_call)
            ctx.register_hook('pre_tool_call', pre_tool_call)
            ctx.register_hook('post_tool_call', post_tool_call)
            ctx.register_hook('pre_approval_request', pre_approval_request)

        """#
    }

    /// ~/.hermes/plugins/nook/plugin.yaml
    static let hermesManifest = """
    name: nook
    version: "1.0"
    description: Nook in de notch (gemaakt door Nook, nook-hook)

    """
}
