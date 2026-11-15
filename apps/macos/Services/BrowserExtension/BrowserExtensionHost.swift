import Foundation

/// The bridge between a Chromium browser and Nook: the native messaging host script the extension's service worker talks
/// to (`nook-browser-host`), and the host manifests that tell each browser where it is and which extension may start it.
/// Like `nook-mcp` the script is Perl, which every Mac has, and holds no logic: it passes the extension's messages to Nook
/// over `browser.sock` and Nook's commands back. Foundation only, so the core tests check it on Linux too.
enum BrowserExtensionHost {
    /// The host's name, as the extension asks for it (`HOST_NAME` in apps/browser-extension/lib/core.js).
    static let name = "app.nook.browser"

    /// The extension's id: fixed by the public key in its manifest, so it is the same wherever it is loaded from. A
    /// browser lets only this extension start the host.
    static let extensionID = "dmnnhilmehmfdcllfemoipncfhmapjld"

    /// Incremented when the script changes; Nook rewrites it on launch when needed.
    static let version = 2

    /// Where each Chromium browser looks for native messaging hosts of this user, under ~/Library/Application Support.
    /// A browser that is not installed has no folder there, and Nook writes nothing for it.
    static let browsers: [(name: String, folder: String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Google Chrome Beta", "Google/Chrome Beta"),
        ("Google Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi")
    ]

    /// The host manifest for one browser: where the script is, and the one extension that may start it.
    static func manifest(scriptPath: String) -> Data {
        let object: [String: Any] = [
            "name": name,
            "description": "Nook: lets Nook's browser extension talk to Nook on this Mac.",
            "path": scriptPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// The manifest files to write: one per browser whose support folder exists in `applicationSupport`.
    static func manifestURLs(applicationSupport: URL, fileManager: FileManager = .default) -> [(browser: String, url: URL)] {
        browsers.compactMap { browser in
            let folder = applicationSupport.appendingPathComponent(browser.folder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let url = folder.appendingPathComponent("NativeMessagingHosts", isDirectory: true).appendingPathComponent(name + ".json")
            return (browser.name, url)
        }
    }

    /// Writes the script and a manifest for every installed Chromium browser. Returns the browsers it set up. Safe to
    /// call again: files that are already right are left alone.
    @discardableResult
    static func install(script: URL, applicationSupport: URL, fileManager: FileManager = .default) throws -> [String] {
        if (try? String(contentsOf: script, encoding: .utf8)) != contents {
            try contents.write(to: script, atomically: true, encoding: .utf8)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manifest = manifest(scriptPath: script.path)
        var installed: [String] = []
        for target in manifestURLs(applicationSupport: applicationSupport, fileManager: fileManager) {
            try fileManager.createDirectory(at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: target.url)) != manifest { try manifest.write(to: target.url, options: .atomic) }
            installed.append(target.browser)
        }
        return installed
    }

    /// The browsers that have Nook's host manifest now (pointing at `script`).
    static func installedBrowsers(script: URL, applicationSupport: URL, fileManager: FileManager = .default) -> [String] {
        let manifest = manifest(scriptPath: script.path)
        return manifestURLs(applicationSupport: applicationSupport, fileManager: fileManager)
            .filter { (try? Data(contentsOf: $0.url)) == manifest }
            .map(\.browser)
    }

    /// Removes the manifests (the browsers then cannot start the host) and the script.
    static func uninstall(script: URL, applicationSupport: URL, fileManager: FileManager = .default) {
        for target in manifestURLs(applicationSupport: applicationSupport, fileManager: fileManager) {
            try? fileManager.removeItem(at: target.url)
        }
        try? fileManager.removeItem(at: script)
    }

    static let contents = #"""
    #!/usr/bin/perl
    # Nook browser host (version 2): the native messaging host of Nook's browser extension. Chrome (or Brave, Edge, Arc,
    # Vivaldi, Chromium) starts it for the extension and talks to it over stdin and stdout; it passes every message on to
    # Nook over a local Unix socket that only your user can open, and Nook's commands back to the extension. It holds no
    # logic of its own and keeps nothing. Without Nook it stays quiet and tells the extension that Nook is not running.
    # See docs/BROWSER-EXTENSION.md.
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use IO::Select;
    use JSON::PP;

    my $sock_path = $ENV{NOOK_BROWSER_SOCK} // "$ENV{HOME}/Library/Application Support/Nook/browser.sock";
    my $json = JSON::PP->new->utf8->canonical;
    # One id per browser that runs the extension, so Nook tells two browsers apart.
    my $client = sprintf('%d-%d-%04x', $$, time, int(rand(65536)));
    my $max_message = 64 * 1024 * 1024;

    $SIG{PIPE} = 'IGNORE';
    binmode STDIN;
    binmode STDOUT;

    my $running;
    my $poll;
    my $poll_buffer = '';
    my $poll_started = 0;

    while (1) {
        open_poll() unless $poll;
        my $select = IO::Select->new(\*STDIN);
        $select->add($poll) if $poll;
        for my $handle ($select->can_read($poll ? 5 : 3)) {
            if (fileno($handle) == fileno(STDIN)) { from_browser(); }
            else { from_poll(); }
        }
        # Nook answers a poll within half a minute; one that hangs longer is dropped and asked again.
        close_poll() if $poll && time - $poll_started > 60;
    }

    # A message from the extension: passed to Nook, and Nook's answer goes back with the extension's request id.
    sub from_browser {
        my $header = read_exact(4);
        exit 0 unless defined $header;
        my $length = unpack('L', $header);
        exit 1 if $length > $max_message;
        my $body = read_exact($length);
        exit 0 unless defined $body;
        my $message = eval { $json->decode($body) };
        return unless ref($message) eq 'HASH';
        my $rid = $message->{rid};
        my $reply = ask_nook($message, 15);
        if (defined $reply) { set_running(1); }
        else {
            set_running(0);
            $reply = { ok => JSON::PP::false, error => 'Nook is not running on this Mac.' };
        }
        write_frame({ kind => 'reply', rid => $rid, reply => $reply }) if defined $rid;
    }

    # A line on the waiting poll: a command for the extension, a change in a conversation its side panel follows, or
    # "idle" when Nook had nothing for half a minute.
    sub from_poll {
        my $read = sysread($poll, $poll_buffer, 65536, length $poll_buffer);
        if (!$read) {
            close_poll();
            return;
        }
        return unless $poll_buffer =~ /\n/;
        my ($line) = split /\n/, $poll_buffer, 2;
        close_poll();
        my $message = eval { $json->decode($line) };
        return unless ref($message) eq 'HASH';
        write_frame($message) if defined $message->{kind} && ($message->{kind} eq 'command' || $message->{kind} eq 'chat');
    }

    sub open_poll {
        my $socket = -S $sock_path ? IO::Socket::UNIX->new(Peer => $sock_path) : undef;
        unless ($socket) {
            set_running(0);
            return;
        }
        $socket->autoflush(1);
        print $socket $json->encode({ client => $client, message => { kind => 'poll' } }), "\n";
        $poll = $socket;
        $poll_buffer = '';
        $poll_started = time;
        set_running(1);
    }

    sub close_poll {
        close $poll if $poll;
        $poll = undef;
        $poll_buffer = '';
    }

    sub ask_nook {
        my ($message, $timeout) = @_;
        return undef unless -S $sock_path;
        my $line;
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm $timeout;
            my $socket = IO::Socket::UNIX->new(Peer => $sock_path);
            if ($socket) {
                print $socket $json->encode({ client => $client, message => $message }), "\n";
                $socket->flush;
                $line = <$socket>;
                close $socket;
            }
            alarm 0;
        };
        alarm 0;
        return undef unless defined $line;
        chomp $line;
        my $reply = eval { $json->decode($line) };
        return ref($reply) eq 'HASH' ? $reply : undef;
    }

    # Tells the extension when Nook comes or goes, once per change.
    sub set_running {
        my ($now) = @_;
        return if defined $running && $running == $now;
        $running = $now;
        write_frame({ kind => 'nook', running => $now ? JSON::PP::true : JSON::PP::false });
    }

    sub read_exact {
        my ($length) = @_;
        my $buffer = '';
        while (length($buffer) < $length) {
            my $read = sysread(STDIN, $buffer, $length - length($buffer), length $buffer);
            return undef unless $read;
        }
        return $buffer;
    }

    # Chrome reads a 32-bit length in the Mac's own byte order, then the JSON.
    sub write_frame {
        my ($message) = @_;
        my $body = $json->encode($message);
        my $data = pack('L', length $body) . $body;
        my $offset = 0;
        while ($offset < length $data) {
            my $written = syswrite(STDOUT, $data, length($data) - $offset, $offset);
            exit 0 unless defined $written && $written > 0;
            $offset += $written;
        }
    }
    """#
}
