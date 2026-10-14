import Foundation
import AppKit

/// Het kleine script dat agents (Claude Code, Codex, Gemini CLI, Cursor, Copilot, …) en de plugins van OpenCode, Amp en Hermes aanroepen om Nook iets te laten weten.
/// Het is een Perl-script (Perl staat standaard op macOS) en heet nog steeds nook-hook.sh, zodat bestaande
/// koppelingen blijven werken. Draait Nook niet, of duurt het te lang, dan doet het niets en gaat de agent gewoon door.
enum HookScript {
    /// Gaat omhoog als het script verandert; Nook schrijft het dan bij het opstarten opnieuw.
    static let version = 3

    static let contents = #"""
    #!/usr/bin/perl
    # Nook hook (versie 3): stuurt een gebeurtenis van een agent naar Nook, lokaal via een Unix-socket.
    # Draait Nook niet, of duurt het te lang, dan doet dit script niets: de agent gaat gewoon door.
    #   --agent <naam>   wie de gebeurtenis stuurt (claude-code, codex, gemini, cursor, copilot, …)
    #                    Zonder --agent telt het veld "nook_agent" in de JSON (a-z, 0-9, - en _, max. 32 tekens).
    #   <Gebeurtenis>    naam van de gebeurtenis, als de agent die zelf niet in de JSON zet
    #   --wait           wacht op jouw antwoord in de notch (toestemming)
    #   --ask            beantwoord een vraag van de agent (AskUserQuestion) in de notch
    #   --statusline     geef het abonnementsgebruik door en toon een statusregel
    # Zie docs/AGENTS.md voor hoe elke agent zich zo bij Nook kan melden.
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use JSON::PP;

    my $sock_path = "$ENV{HOME}/Library/Application Support/Nook/hub.sock";
    my $prev_file = "$ENV{HOME}/Library/Application Support/Nook/statusline-previous.json";
    my $agent = 'claude-code';
    my $agent_given = 0;
    my $mode = 'event';
    my $payload = '';
    my $event_name = '';
    my $event = {};
    my $done = 0;

    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--agent') {
            my $next = shift @ARGV;
            if (defined $next) { $agent = $next; $agent_given = 1; }
        }
        elsif ($arg eq '--wait') { $mode = 'permission'; }
        elsif ($arg eq '--ask') { $mode = 'ask'; }
        elsif ($arg eq '--statusline') { $mode = 'statusline'; }
        elsif ($arg =~ /^\s*\{/) { $payload = $arg; }
        elsif ($event_name eq '') { $event_name = $arg; }
    }

    $SIG{ALRM} = sub { finish(''); };
    $SIG{PIPE} = 'IGNORE';

    alarm 5;
    if ($payload eq '') {
        local $/;
        my $in = <STDIN>;
        $payload = defined $in ? $in : '';
    }
    $event = eval { decode_json($payload) };
    $event = {} unless ref($event) eq 'HASH';
    if ($event_name ne '' && !defined $event->{hook_event_name}) { $event->{hook_event_name} = $event_name; }
    unless ($agent_given) {
        my $tag = first_text($event->{nook_agent});
        $agent = $tag if defined $tag && $tag =~ /^[a-z0-9][a-z0-9_-]{0,31}$/;
    }
    fill_fields($event) unless $mode eq 'statusline';
    my $name = first_text($event->{hook_event_name});
    $name = '' unless defined $name;
    $mode = 'permission' if $name eq 'PermissionRequest' || $name eq 'permissionRequest';

    my %env = map { ($_ => (defined $ENV{$_} ? $ENV{$_} : '')) }
        qw(TERM_PROGRAM __CFBundleIdentifier ITERM_SESSION_ID TERM_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR CODEX_HOME NOOK_RUN_ID);

    # nook_show_step: een agent die alleen "klaar" meldt, krijgt de stap toch te zien (eerst begonnen, dan klaar).
    my @events = ($event);
    if ($mode eq 'event' && $event->{nook_show_step}) {
        my %before = %$event;
        $before{hook_event_name} = 'PreToolUse';
        $event->{hook_event_name} = 'PostToolUse';
        @events = (\%before, $event);
    }
    delete $_->{nook_show_step} for @events;

    alarm($mode eq 'permission' ? 115 : $mode eq 'ask' ? 125 : 3);
    my $reply = '';
    for my $item (@events) {
        $reply = send_line(encode_json({ agent => $agent, mode => $mode, env => \%env, event => $item }) . "\n");
    }
    finish($reply);

    sub send_line {
        my ($message) = @_;
        return '' unless -S $sock_path;
        my $s = IO::Socket::UNIX->new(Peer => $sock_path);
        return '' unless $s;
        print $s $message;
        $s->flush;
        my $line = <$s>;
        close $s;
        return defined $line ? $line : '';
    }

    sub finish {
        my ($out) = @_;
        alarm 0;
        exit 0 if $done;
        $done = 1;
        $out = '' unless defined $out;
        chomp $out;
        if ($mode eq 'statusline') {
            statusline();
        } elsif ($agent eq 'copilot' && $mode eq 'permission') {
            print copilot_decision($out), "\n";
        } elsif ($out ne '') {
            print "$out\n";
        } elsif ($agent eq 'gemini' || $agent eq 'antigravity' || $agent eq 'copilot') {
            # Deze agents willen altijd JSON terug; een leeg object betekent: Nook beslist niets.
            print "{}\n";
        }
        exit 0;
    }

    # Copilot CLI wil bij toestemming altijd geldige JSON. Zonder antwoord uit de notch vraagt hij het zelf ("ask").
    sub copilot_decision {
        my ($out) = @_;
        my $answer = eval { decode_json($out) };
        my $behavior = '';
        if (ref($answer) eq 'HASH' && ref($answer->{hookSpecificOutput}) eq 'HASH'
            && ref($answer->{hookSpecificOutput}{decision}) eq 'HASH') {
            my $value = first_text($answer->{hookSpecificOutput}{decision}{behavior});
            $behavior = $value if defined $value;
        }
        return '{"permissionDecision":"allow"}' if $behavior eq 'allow';
        return '{"permissionDecision":"deny"}' if $behavior eq 'deny';
        return '{"permissionDecision":"ask"}';
    }

    # Velden van andere agents (Copilot, Cursor, Antigravity, Gemini) onder de namen die Nook kent,
    # zoals Claude Code ze gebruikt. Wat er al staat, blijft staan.
    sub fill_fields {
        my ($e) = @_;
        my $call = ref($e->{toolCall}) eq 'HASH' ? $e->{toolCall} : {};
        if (!defined $e->{tool_name}) {
            my $tool = first_text($e->{toolName}, $call->{name}, $e->{tool});
            $e->{tool_name} = $tool if defined $tool;
        }
        if (!defined $e->{tool_input}) {
            my $args = $e->{toolArgs};
            if (defined $args && !ref($args)) { $args = eval { decode_json($args) }; }
            if (ref($args) eq 'HASH') {
                $e->{tool_input} = $args;
            } elsif (ref($call->{args}) eq 'HASH') {
                my %flat = %{ $call->{args} };
                for my $pair (['CommandLine', 'command'], ['FilePath', 'file_path'], ['Path', 'path'],
                              ['Url', 'url'], ['Query', 'query'], ['Pattern', 'pattern']) {
                    if (defined $flat{$pair->[0]} && !defined $flat{$pair->[1]}) {
                        $flat{$pair->[1]} = $flat{$pair->[0]};
                    }
                }
                $e->{tool_input} = \%flat;
            }
        }
        if (!defined first_text($e->{session_id})) {
            my $sid = first_text($e->{conversationId}, $e->{sessionId});
            if (!defined $sid && ($agent eq 'gemini' || $agent eq 'antigravity')) {
                $sid = first_text($ENV{GEMINI_SESSION_ID});
            }
            $e->{session_id} = $sid if defined $sid;
        }
        if (!defined first_text($e->{cwd})) {
            my $cwd = first_text($e->{workdir});
            for my $key ('workspacePaths', 'workspace_roots') {
                last if defined $cwd;
                $cwd = first_text($e->{$key}->[0]) if ref($e->{$key}) eq 'ARRAY';
            }
            $e->{cwd} = $cwd if defined $cwd;
        }
        # Cursor meldt een stop met een fout als status "error".
        my $stop = first_text($e->{hook_event_name});
        my $status = first_text($e->{status});
        if (defined $stop && ($stop eq 'stop' || $stop eq 'Stop') && defined $status && $status eq 'error') {
            $e->{hook_event_name} = 'StopFailure';
        }
    }

    # De eerste waarde die gewone, niet-lege tekst is.
    sub first_text {
        for my $value (@_) {
            return $value if defined $value && !ref($value) && $value ne '';
        }
        return undef;
    }

    # Toont de statusregel die je al had (als die er was), anders een korte eigen regel.
    sub statusline {
        if (-f $prev_file) {
            my $cmd = eval {
                open(my $fh, '<', $prev_file) or die;
                local $/;
                my $saved = decode_json(<$fh>);
                close $fh;
                $saved->{command};
            };
            if (defined $cmd && $cmd ne '') {
                require IPC::Open2;
                my ($out, $in);
                my $pid = eval { IPC::Open2::open2($out, $in, '/bin/sh', '-c', $cmd) };
                if ($pid) {
                    print $in $payload;
                    close $in;
                    local $/;
                    my $text = <$out>;
                    waitpid($pid, 0);
                    print $text if defined $text;
                    return;
                }
            }
        }
        my @parts;
        if (ref($event->{model}) eq 'HASH' && defined $event->{model}{display_name}) {
            push @parts, $event->{model}{display_name};
        }
        my $limits = ref($event->{rate_limits}) eq 'HASH' ? $event->{rate_limits} : {};
        for my $pair (['five_hour', '5u'], ['seven_day', 'week']) {
            my $window = $limits->{$pair->[0]};
            if (ref($window) eq 'HASH' && defined $window->{used_percentage}) {
                push @parts, sprintf('%s %d%%', $pair->[1], $window->{used_percentage});
            }
        }
        print join(' · ', @parts), "\n";
    }
    """#

    /// Schrijft het script als het ontbreekt of verouderd is. Veilig om bij elke start aan te roepen.
    @discardableResult
    static func install() throws -> URL {
        let url = NookPaths.hookScriptURL
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return url
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Het commando zoals het in een configuratiebestand komt (pad met spaties, dus tussen aanhalingstekens).
    static func command(_ arguments: String) -> String {
        "\"\(NookPaths.hookScriptURL.path)\" \(arguments)"
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
