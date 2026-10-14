import Foundation
import AppKit

/// Het kleine script dat agents (Claude Code, Codex, Gemini CLI, …) aanroepen om Nook iets te laten weten.
/// Het is een Perl-script (Perl staat standaard op macOS) en heet nog steeds nook-hook.sh, zodat bestaande
/// koppelingen blijven werken. Draait Nook niet, of duurt het te lang, dan doet het niets en gaat de agent gewoon door.
enum HookScript {
    /// Gaat omhoog als het script verandert; Nook schrijft het dan bij het opstarten opnieuw.
    static let version = 2

    static let contents = #"""
    #!/usr/bin/perl
    # Nook hook (versie 2): stuurt een gebeurtenis van een agent naar Nook, lokaal via een Unix-socket.
    # Draait Nook niet, of duurt het te lang, dan doet dit script niets: de agent gaat gewoon door.
    #   --agent <naam>   wie de gebeurtenis stuurt (claude-code, codex, gemini, …)
    #   --wait           wacht op jouw antwoord in de notch (toestemming)
    #   --ask            beantwoord een vraag van de agent (AskUserQuestion) in de notch
    #   --statusline     geef het abonnementsgebruik door en toon een statusregel
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use JSON::PP;

    my $sock_path = "$ENV{HOME}/Library/Application Support/Nook/hub.sock";
    my $prev_file = "$ENV{HOME}/Library/Application Support/Nook/statusline-previous.json";
    my $agent = 'claude-code';
    my $mode = 'event';
    my $payload = '';
    my $event_name = '';
    my $event = {};
    my $done = 0;

    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--agent') { my $next = shift @ARGV; $agent = $next if defined $next; }
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
    my $name = defined $event->{hook_event_name} ? $event->{hook_event_name} : '';
    $mode = 'permission' if $name eq 'PermissionRequest' || $name eq 'permissionRequest';

    my %env = map { ($_ => (defined $ENV{$_} ? $ENV{$_} : '')) }
        qw(TERM_PROGRAM __CFBundleIdentifier ITERM_SESSION_ID TERM_SESSION_ID CLAUDE_CODE_ENTRYPOINT);
    my $message = encode_json({ agent => $agent, mode => $mode, env => \%env, event => $event }) . "\n";

    alarm($mode eq 'permission' ? 115 : $mode eq 'ask' ? 125 : 3);
    my $reply = '';
    if (-S $sock_path) {
        my $s = IO::Socket::UNIX->new(Peer => $sock_path);
        if ($s) {
            print $s $message;
            $s->flush;
            my $line = <$s>;
            $reply = $line if defined $line;
            close $s;
        }
    }
    finish($reply);

    sub finish {
        my ($out) = @_;
        alarm 0;
        exit 0 if $done;
        $done = 1;
        $out = '' unless defined $out;
        chomp $out;
        if ($mode eq 'statusline') {
            statusline();
        } elsif ($out ne '') {
            print "$out\n";
        } elsif ($agent eq 'gemini') {
            print "{}\n";
        }
        exit 0;
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
