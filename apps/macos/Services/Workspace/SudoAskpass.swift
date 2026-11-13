import Foundation

/// `sudo -A` for agents: every session Nook starts gets `SUDO_ASKPASS` pointing at this helper. When an agent runs
/// `sudo -A …`, sudo runs the helper, the helper asks Nook over `bridge.sock`, and Nook shows a private card with the command
/// sudo was started with and a password field. What you type goes back to sudo on stdout, and nowhere else: not to the
/// agent (it only sees sudo's own output), not to the timeline, not to the action log (that records "sudo" and the
/// decision). Without Nook, or when you decline, the helper exits 1 and sudo fails as it would after a wrong password.
///
/// The protocol is one JSON line each way:
///   helper → Nook  `{"askpass": {"prompt": "…", "command": "…"}, "agent": "askpass", "cwd": "…", "env": {"NOOK_RUN_ID": "…", "NOOK_BRIDGE_TOKEN": "…"}}` (the token read from the session's `NOOK_BRIDGE_TOKEN_FILE`)
///   Nook → helper  `{"ok": true, "value": "…"}` or `{"ok": false}`
enum SudoAskpass {
    /// Incremented when the script changes; Nook rewrites it on launch when needed.
    static let version = 2
    /// The agent id the helper names itself with; it never takes a session's rights.
    static let agentID = "askpass"
    /// How long the helper waits for your answer: as long as any bridge request does.
    static let timeout = 600

    /// What sudo asked and for which command, as the helper sent it.
    struct Request: Equatable {
        var prompt: String
        var command: String
    }

    /// The request in a message on the bridge socket, or nil when the message is not one.
    static func request(in object: [String: Any]) -> Request? {
        guard let body = object["askpass"] as? [String: Any] else { return nil }
        let prompt = (body["prompt"] as? String) ?? ""
        let command = (body["command"] as? String) ?? ""
        // Both come from the agent's side: kept short and on one line each, so they cannot fake the card's layout.
        return Request(prompt: oneLine(prompt, limit: 200), command: oneLine(command, limit: 2_000))
    }

    /// What the password is for, as the card says it: the command sudo will run as administrator, or none when the agent
    /// only checks that sudo works (`sudo -v`, `sudo -A true`, `sudo -l`), which runs nothing itself.
    struct Purpose: Equatable {
        /// The command after `sudo` and its options, as it will run; empty for a check.
        var command: String
        var isCheck: Bool { command.isEmpty }
    }

    /// Reads the command line sudo was started with (`sudo -A -u root make install`) into what it will run.
    static func purpose(of commandLine: String) -> Purpose {
        var words = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, (first as NSString).lastPathComponent == "sudo" else {
            return Purpose(command: commandLine.trimmingCharacters(in: .whitespaces))
        }
        words.removeFirst()
        // sudo's options before the command; these take a value as the next word.
        let withValue: Set<String> = ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "-R"]
        var checkOnly = false
        while let word = words.first, word.hasPrefix("-") {
            words.removeFirst()
            if word == "--" { break }
            if ["-v", "--validate", "-l", "--list"].contains(word) { checkOnly = true }
            if withValue.contains(word), !words.isEmpty { words.removeFirst() }
        }
        let rest = words.joined(separator: " ")
        if checkOnly || ["", "true", "/usr/bin/true", "/bin/true", ":"].contains(rest) { return Purpose(command: "") }
        return Purpose(command: rest)
    }

    /// Nook's answer to the helper: the value to give sudo, or nil to decline.
    static func reply(_ value: String?) -> Data {
        let object: [String: Any] = value.map { ["ok": true, "value": $0] } ?? ["ok": false]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
    }

    /// The value in Nook's answer, as the helper reads it (the tests check both sides of the protocol with this).
    static func value(inReply data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["ok"] as? Bool) == true, let value = object["value"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// What the agent's process gets in its environment.
    static func environment(script: String) -> [String: String] { ["SUDO_ASKPASS": script] }

    /// What every session Nook starts on this Mac gets: `SUDO_ASKPASS`, when the helper is in place. A session on another
    /// machine never gets it (the helper lives on this Mac); `RemoteLaunch` leaves the local environment behind anyway.
    static func launchEnvironment(at url: URL = NookPaths.askpassScriptURL,
                                  fileManager: FileManager = .default) -> [String: String] {
        fileManager.isExecutableFile(atPath: url.path) ? environment(script: url.path) : [:]
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static let contents = #"""
    #!/usr/bin/perl
    # Nook sudo helper (version 2): sudo runs it for `sudo -A` (SUDO_ASKPASS). It asks Nook for the password over a local
    # Unix socket that only your user can open; Nook shows you the command and a password field. The password goes to sudo
    # on stdout and nowhere else. Without Nook, or when you decline, it exits 1. See docs/WORKSPACE-AGENTS.md.
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use JSON::PP;
    use Cwd qw(getcwd);

    my $sock_path = $ENV{NOOK_BRIDGE_SOCK} // "$ENV{HOME}/Library/Application Support/Nook/bridge.sock";
    my $prompt = defined $ARGV[0] ? $ARGV[0] : '';
    my $parent = getppid();
    my $command = $parent =~ /^\d+$/ ? `/bin/ps -o args= -p $parent 2>/dev/null` : '';
    $command = '' unless defined $command;
    chomp $command;
    my $cwd = getcwd();
    $cwd = (defined $ENV{PWD} ? $ENV{PWD} : '') unless defined $cwd;
    my %env = map { ($_ => (defined $ENV{$_} ? $ENV{$_} : '')) } qw(NOOK_RUN_ID NOOK_BRIDGE_TOKEN);
    # The session's token from its file (NOOK_BRIDGE_TOKEN_FILE), as the MCP server reads it.
    if ($env{NOOK_BRIDGE_TOKEN} eq '' && defined $ENV{NOOK_BRIDGE_TOKEN_FILE} && open(my $fh, '<', $ENV{NOOK_BRIDGE_TOKEN_FILE})) {
        local $/;
        my $token = <$fh>;
        close $fh;
        $token = '' unless defined $token;
        $token =~ s/\s+\z//;
        $env{NOOK_BRIDGE_TOKEN} = $token;
    }
    my $json = JSON::PP->new->utf8->canonical;
    unless (-S $sock_path) {
        print STDERR "Nook is not running, so it cannot ask for the password.\n";
        exit 1;
    }
    my $reply = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 600;
        my $s = IO::Socket::UNIX->new(Peer => $sock_path);
        if ($s) {
            print $s $json->encode({ agent => 'askpass', cwd => $cwd, env => \%env,
                                     askpass => { prompt => $prompt, command => $command } }) . "\n";
            $s->flush;
            my $got = <$s>;
            close $s;
            $reply = defined $got ? $got : '';
        }
        alarm 0;
    };
    alarm 0;
    my $answer = eval { $json->decode($reply) };
    if (ref($answer) eq 'HASH' && $answer->{ok} && defined $answer->{value} && $answer->{value} ne '') {
        print $answer->{value}, "\n";
        exit 0;
    }
    print STDERR "The password was not given in Nook.\n";
    exit 1;
    """#

    /// Writes the helper if missing or outdated (0700: only you may run or read it). Safe to call on every launch.
    @discardableResult
    static func install(at url: URL = NookPaths.askpassScriptURL) throws -> URL {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { return url }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
