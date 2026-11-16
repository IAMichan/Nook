import Foundation

/// `nook-keeper`: one small process per session that holds the agent, so the agent goes on when Nook quits, updates or
/// crashes (Settings › Agents, off by default). It is Perl, which every Mac has. It writes everything the agent prints to a
/// file in the session's folder here, and Nook reads on from where it stopped when it comes back.
///
/// Frames, both ways: one byte of kind, four bytes of length (big-endian), the payload.
///   To the keeper:   A <8 bytes offset> attach, replaying stdout from there · I data for stdin · C close stdin
///                    S <decimal signal> signal the agent's group · T stop it: interrupt, terminate, kill, and clean up
///                    Q forget everything (the agent has ended)
///   From the keeper: P <decimal pid> · O stdout · E stderr · X <decimal status> the agent ended
/// The socket and the spool are in a folder only you can enter. Foundation only, tested with real processes.
enum SessionKeeper {
    enum Kind: UInt8 {
        case attach = 0x41, stdin = 0x49, closeInput = 0x43, signal = 0x53, stop = 0x54, quit = 0x51
        case pid = 0x50, stdout = 0x4F, stderr = 0x45, exit = 0x58
    }

    struct Frame: Equatable, Sendable {
        var kind: Kind
        var payload: Data
    }

    static func encode(_ kind: Kind, _ payload: Data = Data()) -> Data {
        var out = Data([kind.rawValue])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func attach(offset: UInt64) -> Data {
        var payload = Data()
        withUnsafeBytes(of: offset.bigEndian) { payload.append(contentsOf: $0) }
        return encode(.attach, payload)
    }

    /// Takes the complete frames off the front of `buffer`. An unknown kind ends the stream: nil.
    static func decode(_ buffer: inout Data) -> [Frame]? {
        var frames: [Frame] = []
        var index = buffer.startIndex
        while buffer.endIndex - index >= 5 {
            guard let kind = Kind(rawValue: buffer[index]) else { return nil }
            let length = buffer[(index + 1)..<(index + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard buffer.endIndex - index - 5 >= length else { break }
            let start = index + 5
            frames.append(Frame(kind: kind, payload: Data(buffer[start..<(start + length)])))
            index = start + length
        }
        buffer = Data(buffer[index...])
        return frames
    }

    /// The folder of a kept session; `uuid` keeps its socket path short enough.
    static func folder(base: URL, id: UUID) -> URL { base.appendingPathComponent(id.uuidString.prefix(8).lowercased(), isDirectory: true) }

    /// The command that starts a keeper. It answers once its socket listens, and ends: the keeper itself runs on alone.
    static func arguments(script: String, folder: String, workingDirectory: String, keepsInputOpen: Bool,
                          executable: String, arguments: [String]) -> [String] {
        [script, folder, workingDirectory, keepsInputOpen ? "1" : "0", "--", executable] + arguments
    }

    static let contents = #"""
    #!/usr/bin/perl
    # nook-keeper: holds one coding agent, so it goes on while Nook is closed. See SessionKeeper.swift.
    #   nook-keeper <folder> <working directory> <keep stdin open: 0|1> -- <program> <arguments…>
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use IO::Select;
    use POSIX qw(setsid :sys_wait_h);
    use Fcntl;

    my ($folder, $cwd, $keep_input, $dash, @command) = @ARGV;
    die "usage\n" unless defined $dash && $dash eq '--' && @command;
    umask 0077;
    my $sock_path = "$folder/sock";
    my $spool_path = "$folder/out";
    unlink $sock_path;
    my $server = IO::Socket::UNIX->new(Local => $sock_path, Listen => 4) or die "socket: $!\n";

    # Detach: the program that started this ends, this runs on in a session of its own.
    my $daemon = fork() // die "fork: $!\n";
    if ($daemon) { print "ready\n"; exit 0; }
    setsid();
    $SIG{PIPE} = 'IGNORE';
    open(STDIN, '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');

    pipe(my $in_read, my $in_write) or exit 1;
    pipe(my $out_read, my $out_write) or exit 1;
    pipe(my $err_read, my $err_write) or exit 1;
    my $pid = fork() // exit 1;
    if ($pid == 0) {
        setpgrp(0, 0);
        close $_ for ($in_write, $out_read, $err_read, $server);
        $SIG{PIPE} = 'DEFAULT';
        open(STDIN, '<&', $keep_input ? $in_read : do { open(my $null, '<', '/dev/null'); $null });
        open(STDOUT, '>&', $out_write);
        open(STDERR, '>&', $err_write);
        chdir $cwd or POSIX::_exit(127);
        exec { $command[0] } @command;
        POSIX::_exit(127);
    }
    close $_ for ($in_read, $out_write, $err_write);
    setpgrp($pid, 0);
    undef $in_write unless $keep_input;
    open(my $spool, '>>:raw', $spool_path) or exit 1;
    $spool->autoflush(1);
    my $spooled = -s $spool_path // 0;
    my $select = IO::Select->new($server, $out_read, $err_read);
    my ($client, $client_in, $to_child, $to_client, $status) = (undef, '', '', '', undef);
    my $close_input = 0;
    my $replay;    # a read handle while a client catches up on the spool
    my $alone_since = time;
    my ($stop_at, $stop_step, $stop_clean) = (undef, 0, 0);

    sub frame { my ($kind, $data) = @_; return $kind . pack('N', length $data) . $data; }
    sub drop_client {
        return unless $client;
        $select->remove($client);
        close $client;
        ($client, $client_in, $to_client, $replay) = (undef, '', '', undef);
        $alone_since = time;
    }
    sub handle_frames {
        while (length($client_in) >= 5) {
            my ($kind, $length) = unpack('aN', substr($client_in, 0, 5));
            last if length($client_in) < 5 + $length;
            my $data = substr($client_in, 5, $length);
            substr($client_in, 0, 5 + $length) = '';
            if ($kind eq 'A') {
                my ($high, $low) = unpack('NN', $data);
                open($replay, '<:raw', $spool_path) or undef $replay;
                seek($replay, $high * 4294967296 + $low, 0) if $replay;
                $to_client .= frame('P', $pid);
            } elsif ($kind eq 'I') {
                $to_child .= $data if $in_write;
            } elsif ($kind eq 'C') {
                $close_input = 1;
            } elsif ($kind eq 'S') {
                kill($data, -$pid) if !defined $status && $data =~ /^\d+$/;
            } elsif ($kind eq 'T') {
                $stop_at = time;
                $stop_step = 0;
                $stop_clean = 1;
            } elsif ($kind eq 'Q') {
                unlink $sock_path, $spool_path, "$folder/handled";
                rmdir $folder;
                exit 0;
            }
        }
    }

    while (1) {
        my $writes = IO::Select->new();
        $writes->add($client) if $client && length $to_client;
        $writes->add($in_write) if $in_write && length $to_child;
        my ($readable, $writable) = IO::Select->select($select, $writes, undef, 1);
        for my $handle (@{ $readable // [] }) {
            if ($handle == $server) {
                my $next = $server->accept or next;
                drop_client();
                $client = $next;
                $client->blocking(0);
                $select->add($client);
            } elsif ($client && $handle == $client) {
                my $read = sysread($client, my $data, 65536);
                if (!$read) { drop_client(); next; }
                $client_in .= $data;
                handle_frames();
            } elsif ($handle == $out_read) {
                my $read = sysread($out_read, my $data, 65536);
                if (!$read) { $select->remove($out_read); next; }
                print $spool $data;
                $spooled += $read;
            } elsif ($handle == $err_read) {
                my $read = sysread($err_read, my $data, 65536);
                if (!$read) { $select->remove($err_read); next; }
                $to_client .= frame('E', $data) if $client;
            }
        }
        for my $handle (@{ $writable // [] }) {
            if ($client && $handle == $client) {
                my $sent = syswrite($client, $to_client, 65536);
                if (defined $sent) { substr($to_client, 0, $sent) = ''; } else { drop_client(); }
            } elsif ($in_write && $handle == $in_write) {
                my $sent = syswrite($in_write, $to_child, 65536);
                if (defined $sent) { substr($to_child, 0, $sent) = ''; } else { undef $in_write; $to_child = ''; }
            }
        }
        if ($close_input && $in_write && !length $to_child) { undef $in_write; }
        # The spool is the one source of stdout: a live client reads it as a replay that never ends.
        if ($client && $replay && length($to_client) < 262144) {
            seek($replay, 0, 1);
            my $read = read($replay, my $data, 65536);
            $to_client .= frame('O', $data) if $read;
        }
        if (!defined $status && waitpid($pid, WNOHANG) == $pid) { $status = WIFSIGNALED($?) ? WTERMSIG($?) : WEXITSTATUS($?); }
        # Stopping does not need anyone connected: it goes on after Nook has quit.
        if (defined $stop_at && !defined $status && time >= $stop_at) {
            kill((qw(INT TERM KILL))[$stop_step], -$pid);
            $stop_step = $stop_step < 2 ? $stop_step + 1 : 2;
            $stop_at = time + 4;
        }
        # With Nook connected it hears the end as usual below; with nobody there is nothing left to tell.
        if ($stop_clean && defined $status && !$client) { unlink $sock_path, $spool_path, "$folder/handled"; rmdir $folder; exit 0; }
        # Ended, everything read from the agent and handed over: say so.
        if (defined $status && !$select->exists($out_read) && $client && $replay && eof($replay) && !length $to_client) {
            my $done = frame('X', $status);
            syswrite($client, $done);
            undef $replay;
        }
        # Nobody came for a week: it is not worth keeping.
        if (defined $status && !$client && time - $alone_since > 604800) { unlink $sock_path, $spool_path, "$folder/handled"; rmdir $folder; exit 0; }
    }
    """#

    /// Writes the script when it changed, and returns its path.
    @discardableResult
    static func install(at url: URL = NookPaths.supportDirectory.appendingPathComponent("nook-keeper")) throws -> URL {
        if (try? String(contentsOf: url, encoding: .utf8)) != contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
