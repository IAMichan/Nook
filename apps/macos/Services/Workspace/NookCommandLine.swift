import Foundation

/// `nook`, the command line for scripts (`~/.nook/nook`). Like `nook-mcp` it is Perl, which every Mac has, and carries no
/// rules of its own: each command is a call on `bridge.sock`, the socket only your user can open, and Nook decides. Starting
/// or messaging a session waits for your approval in the notch. See docs/WORKSPACE-AGENTS.md.
enum NookCommandLine {
    /// The name the bridge knows this caller by: it never takes the rights of a session that works in the same folder.
    static let agentID = "cli"

    static let contents = #"""
    #!/usr/bin/perl
    # nook: drive Nook's coding sessions from a script. See docs/WORKSPACE-AGENTS.md.
    # Exit codes: 0 done, 1 failed or refused, 2 the session waits for you, 3 Nook is not running.
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use JSON::PP;
    use Cwd qw(getcwd abs_path);

    my $sock_path = $ENV{NOOK_BRIDGE_SOCK} // "$ENV{HOME}/Library/Application Support/Nook/bridge.sock";
    my $json = JSON::PP->new->utf8->canonical;
    my %option = (limit => 15);
    my @words;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg =~ /^--(json|wait|worktree)$/) { $option{$1} = 1; }
        elsif ($arg =~ /^--(agent|model|limit)$/) { $option{$1} = shift @ARGV; }
        elsif ($arg eq '--help' || $arg eq '-h') { usage(0); }
        else { push @words, $arg; }
    }
    my $command = shift(@words) // '';
    my %answer_of = (
        list   => sub { call('session_list', { limit => int($option{limit}) }) },
        read   => sub { call('session_read', { session_id => need(shift @words) }) },
        search => sub { call('session_search', { query => join(' ', @words) }) },
        tools  => sub {
            my $list = call_method('tools/list', {});
            return { content => [ { type => 'text', text => join("\n", map { $_->{name} } @{ $list->{tools} // [] }) } ],
                     tools => $list->{tools} };
        },
    );
    if ($command eq 'start') {
        my $folder = need(shift @words);
        my %arguments = (folder => abs_path($folder) // $folder, task => message(@words));
        $arguments{agent} = $option{agent} if defined $option{agent};
        $arguments{model} = $option{model} if defined $option{model};
        $arguments{worktree} = JSON::PP::true if $option{worktree};
        my $text = show(call('session_start', \%arguments));
        finish($text =~ /^([0-9A-Fa-f-]{36})/ ? $1 : undef);
    } elsif ($command eq 'send') {
        my $id = need(shift @words);
        show(call('session_send', { session_id => $id, message => message(@words) }));
        finish($id);
    } elsif ($command eq 'wait') {
        $option{wait} = 1;
        finish(need(shift @words));
    } elsif ($command eq 'call') {
        my $tool = need(shift @words);
        my $input = @words ? $words[0] : '{}';
        my $arguments = eval { $json->decode($input) };
        fail("The arguments are not JSON.\n", 1) unless ref($arguments) eq 'HASH';
        show(call($tool, $arguments));
    } elsif ($answer_of{$command}) {
        show($answer_of{$command}->());
    } else {
        usage($command eq '' ? 0 : 1);
    }
    exit 0;

    sub usage {
        my ($code) = @_;
        my $text = <<'USAGE';
    nook list [--limit n]                    your sessions, newest first
    nook read <id>                           what a session did
    nook search <words>                      find sessions by what was said
    nook start <folder> <message|->          start a session [--agent a] [--model m] [--worktree] [--wait]
    nook send <id> <message|->               send a session a message [--wait]
    nook wait <id>                           wait until the session is done or needs you
    nook tools                               list every tool
    nook call <tool> [json]                  call one tool
    Use - to read the message from standard input. --json prints the raw answer.
    Starting and messaging sessions wait for your approval in Nook.
    Exit codes: 0 done, 1 failed or refused, 2 the session waits for you, 3 Nook is not running.
    USAGE
        print { $code ? *STDERR : *STDOUT } $text;
        exit $code;
    }

    sub need {
        my ($value) = @_;
        usage(1) unless defined $value && length $value;
        return $value;
    }

    sub message {
        my @parts = @_;
        my $text = @parts == 1 && $parts[0] eq '-' ? do { local $/; my $in = <STDIN>; $in // '' } : join(' ', @parts);
        utf8::decode($text);
        usage(1) unless $text =~ /\S/;
        return $text;
    }

    sub fail {
        my ($text, $code) = @_;
        print STDERR $text;
        exit $code;
    }

    sub call { my ($tool, $arguments) = @_; return call_method('tools/call', { name => $tool, arguments => $arguments }); }

    sub call_method {
        my ($method, $params) = @_;
        fail("Nook is not running.\n", 3) unless -S $sock_path;
        my $payload = $json->encode({ agent => 'cli', cwd => getcwd() // '', env => {},
            message => { jsonrpc => '2.0', id => 1, method => $method, params => $params } }) . "\n";
        my $reply = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 900;
            my $s = IO::Socket::UNIX->new(Peer => $sock_path) or die "no socket\n";
            print $s $payload;
            $s->flush;
            $reply = <$s> // '';
            close $s;
            alarm 0;
        };
        alarm 0;
        my $answer = eval { $json->decode($reply) };
        fail("Nook did not answer.\n", 3) unless ref($answer) eq 'HASH';
        fail(($answer->{error}{message} // 'Nook refused.') . "\n", 1) if ref($answer->{error}) eq 'HASH';
        return $answer->{result};
    }

    sub text_of {
        my ($result) = @_;
        return join("\n", map { $_->{text} // '' } grep { ref($_) eq 'HASH' } @{ $result->{content} // [] });
    }

    # Prints the answer and returns its text; a tool's error ends the script.
    sub show {
        my ($result) = @_;
        my $text = text_of($result);
        my $out = $option{json} ? $json->encode($result) : do { my $bytes = $text; utf8::encode($bytes); $bytes };
        if ($result->{isError}) { print STDERR $out, "\n"; exit 1; }
        print $out, "\n";
        return $text;
    }

    # With --wait: until the session is done (0), failed (1) or needs you (2).
    sub finish {
        my ($id) = @_;
        return unless $option{wait} && defined $id;
        while (1) {
            my $result = call('session_read', { session_id => $id, status_only => JSON::PP::true });
            fail(text_of($result) . "\n", 1) if $result->{isError};
            my $state = text_of($result);
            exit 0 if $state eq 'completed';
            exit 2 if $state eq 'waiting';
            exit 1 if $state eq 'failed' || $state eq 'cancelled';
            sleep 2;
        }
    }
    """#

    @discardableResult
    static func install() throws -> URL {
        let url = NookPaths.commandLineURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) != contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
