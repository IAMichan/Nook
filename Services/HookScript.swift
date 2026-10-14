import Foundation
import AppKit

/// The lightweight script invoked by agents (Claude Code, Codex, Gemini CLI, Cursor, Copilot, …) and plugins for OpenCode, Amp, and Hermes to notify Nook.
/// It is a Perl script (Perl is installed by default on macOS) named nook-hook.sh for backwards compatibility with existing hooks.
/// If Nook is not running or takes too long, it exits cleanly and the agent continues uninterrupted.
enum HookScript {
    /// Incremented when the script changes; Nook rewrites it on launch when needed.
    static let version = 3

    static let contents = #"""
    #!/usr/bin/perl
    # Nook hook (version 3): delivers an agent event to Nook locally via Unix domain socket.
    # If Nook is not running or times out, this script exits cleanly: the agent proceeds normally.
    #   --agent <name>   identifies sender (claude-code, codex, gemini, cursor, copilot, …)
    #                    Without --agent, "nook_agent" JSON field is used (a-z, 0-9, - and _, max 32 chars).
    #   <Event>          event name if not provided in JSON
    #   --wait           wait for user decision in notch (permission)
    #   --ask            answer an agent question in notch (AskUserQuestion)
    #   --statusline     report plan usage and render statusline
    # See docs/AGENTS.md for details on configuring agent hooks.
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

    # nook_show_step: synthetic tool step (pre then post) for agents that only report completion.
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
            # These agents always require JSON output; an empty object means no intervention from Nook.
            print "{}\n";
        }
        exit 0;
    }

    # Copilot CLI requires valid JSON for decisions. If unanswered from notch, defaults to interactive prompt ("ask").
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

    # Normalize fields from other agents (Copilot, Cursor, Antigravity, Gemini) into Nook's canonical schema
    # matching Claude Code conventions. Existing canonical fields are preserved.
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
        # Cursor reports failure stops with status "error".
        my $stop = first_text($e->{hook_event_name});
        my $status = first_text($e->{status});
        if (defined $stop && ($stop eq 'stop' || $stop eq 'Stop') && defined $status && $status eq 'error') {
            $e->{hook_event_name} = 'StopFailure';
        }
    }

    # Returns the first non-empty scalar string value.
    sub first_text {
        for my $value (@_) {
            return $value if defined $value && !ref($value) && $value ne '';
        }
        return undef;
    }

    # Renders the user's previous statusline if configured, otherwise displays a compact fallback.
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
        for my $pair (['five_hour', '5h'], ['seven_day', 'week']) {
            my $window = $limits->{$pair->[0]};
            if (ref($window) eq 'HASH' && defined $window->{used_percentage}) {
                push @parts, sprintf('%s %d%%', $pair->[1], $window->{used_percentage});
            }
        }
        print join(' · ', @parts), "\n";
    }
    """#

    /// Writes the script if missing or outdated. Safe to call on every launch.
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

    /// Command string for configuration files (quoted to accommodate spaces in path).
    static func command(_ arguments: String) -> String {
        "\"\(NookPaths.hookScriptURL.path)\" \(arguments)"
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
