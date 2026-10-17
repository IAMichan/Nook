import Foundation

/// The MCP server agents start to reach Nook's workspace (`nook-mcp`). Like the hook script it is Perl, which every Mac
/// has, and it carries no logic of its own: each JSON-RPC message goes to Nook over `bridge.sock` and Nook's answer goes
/// back to the agent. When Nook is not running it stays a valid, empty MCP server, so the agent starts and works as usual.
enum WorkspaceBridgeScript {
    /// Incremented when the script changes; Nook rewrites it on launch when needed.
    static let version = 1

    static let contents = #"""
    #!/usr/bin/perl
    # Nook workspace bridge (version 1): an MCP server (stdio) that gives a coding agent Nook's terminal, browser and
    # pull requests. Every request goes to Nook over a local Unix socket that only your user can open; Nook decides what
    # may run directly and asks you in the notch for the rest. Without Nook the tools are simply not there.
    #   --agent <name>   who is asking (claude-code, codex, …)
    # See docs/WERKRUIMTE-AGENTS.md.
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use JSON::PP;
    use Cwd qw(getcwd);

    my $sock_path = "$ENV{HOME}/Library/Application Support/Nook/bridge.sock";
    my $agent = 'agent';
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--agent') {
            my $next = shift @ARGV;
            $agent = $next if defined $next && $next =~ /^[a-z0-9][a-z0-9_-]{0,31}$/;
        }
    }

    $| = 1;
    $SIG{PIPE} = 'IGNORE';
    my $json = JSON::PP->new->utf8->canonical;
    my $cwd = getcwd();
    $cwd = (defined $ENV{PWD} ? $ENV{PWD} : '') unless defined $cwd;
    my %env = map { ($_ => (defined $ENV{$_} ? $ENV{$_} : '')) }
        qw(NOOK_RUN_ID CLAUDE_CONFIG_DIR CODEX_HOME CLAUDE_CODE_ENTRYPOINT);

    while (my $line = <STDIN>) {
        chomp $line;
        next if $line =~ /^\s*$/;
        my $message = eval { $json->decode($line) };
        next unless ref($message) eq 'HASH';
        my $method = (defined $message->{method} && !ref($message->{method})) ? $message->{method} : '';
        # A tool call may wait for your approval in the notch; everything else is quick.
        my $timeout = $method eq 'tools/call' ? 900 : 15;
        my $reply = ask_nook($json->encode({ agent => $agent, cwd => $cwd, env => \%env, message => $message }) . "\n", $timeout);
        next unless exists $message->{id};
        if ($reply ne '') { print $reply, "\n"; }
        else { print $json->encode(offline($message)), "\n"; }
    }
    exit 0;

    sub ask_nook {
        my ($payload, $timeout) = @_;
        return '' unless -S $sock_path;
        my $reply = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm $timeout;
            my $s = IO::Socket::UNIX->new(Peer => $sock_path);
            if ($s) {
                print $s $payload;
                $s->flush;
                my $got = <$s>;
                close $s;
                $reply = defined $got ? $got : '';
            }
            alarm 0;
        };
        alarm 0;
        chomp $reply;
        return $reply;
    }

    # Nook is not running or did not answer: stay a valid MCP server so the agent keeps working.
    sub offline {
        my ($m) = @_;
        my $method = (defined $m->{method} && !ref($m->{method})) ? $m->{method} : '';
        my $result;
        if ($method eq 'initialize') {
            my $version = (ref($m->{params}) eq 'HASH' && defined $m->{params}{protocolVersion})
                ? $m->{params}{protocolVersion} : '2025-06-18';
            $result = { protocolVersion => $version, capabilities => { tools => {} },
                        serverInfo => { name => 'nook', version => '1' } };
        } elsif ($method eq 'tools/list') {
            $result = { tools => [] };
        } elsif ($method eq 'tools/call') {
            $result = { isError => JSON::PP::true, content => [ { type => 'text',
                text => 'Nook did not answer (it is not running, or the request timed out). Its terminal, browser and pull requests are not available right now; carry on without them.' } ] };
        } elsif ($method eq 'ping') {
            $result = {};
        } else {
            return { jsonrpc => '2.0', id => $m->{id}, error => { code => -32601, message => 'Method not found' } };
        }
        return { jsonrpc => '2.0', id => $m->{id}, result => $result };
    }
    """#

    /// Writes the script if missing or outdated. Safe to call on every launch.
    @discardableResult
    static func install() throws -> URL {
        let url = NookPaths.bridgeScriptURL
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            linkSpaceFree(to: url)
            return url
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        linkSpaceFree(to: url)
        return url
    }

    /// Keeps ~/.nook/nook-mcp pointing at the script, for commands typed in a shell.
    private static func linkSpaceFree(to target: URL) {
        let fm = FileManager.default
        let link = NookPaths.spaceFreeBridgeURL
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path { return }
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// Registers the bridge with an agent outside Nook (user scope), typed in a visible terminal so you see what happens.
    static func linkCommand(for provider: RunProvider) -> String {
        let script = TerminalLauncher.shellQuote(NookPaths.spaceFreeBridgeURL.path)
        switch provider {
        case .claude: return "claude mcp add --scope user \(BridgeTool.serverName) -- \(script) --agent claude-code"
        case .codex: return "codex mcp add \(BridgeTool.serverName) -- \(script) --agent codex"
        }
    }
}
