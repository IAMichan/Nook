//! Nook's tools for a session on another machine (`RemoteBridge` and `WorkspaceBridgeScript` on the Mac). Its agent
//! reaches them through a socket ssh forwards (`-R`) to a TCP port of Nook on this computer that only listens on
//! 127.0.0.1, never to the local `bridge`: what comes in there speaks for a run on another machine, proved by a token
//! made for that run, and gets the tools below only. A machine you run an agent on can use Nook's browser and read its
//! own session, but it reaches no other session and can never start anything on this computer.
//!
//! On the machine the server is the same small Perl script the Mac puts there (`SCRIPT`): every Unix-like machine has
//! Perl, and it carries no logic of its own. Without Perl and `JSON::PP` the session runs without these tools.

use std::sync::atomic::{AtomicU16, Ordering};

use base64::Engine;

use super::bridge::BridgeTool;

/// The MCP server on the machine (`nook-mcp`), identical to the Mac's, which reads `NOOK_BRIDGE_SOCK` and
/// `NOOK_BRIDGE_TOKEN_FILE`.
pub const SCRIPT: &str = r#"#!/usr/bin/perl
# Nook workspace bridge (version 3): an MCP server (stdio) that gives a coding agent Nook's terminal, browser and
# pull requests. Every request goes to Nook over a local Unix socket that only your user can open; Nook decides what
# may run directly and asks you in the notch for the rest. Without Nook the tools are simply not there.
#   --agent <name>   who is asking (claude-code, codex, …)
# See docs/WORKSPACE-AGENTS.md.
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP;
use Cwd qw(getcwd);

my $sock_path = $ENV{NOOK_BRIDGE_SOCK} // "$ENV{HOME}/Library/Application Support/Nook/bridge.sock";
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
    qw(NOOK_RUN_ID NOOK_BRIDGE_TOKEN CLAUDE_CONFIG_DIR CODEX_HOME CLAUDE_CODE_ENTRYPOINT);
# The session's token comes from a file of your own (NOOK_BRIDGE_TOKEN_FILE), never from the command line, where
# every process on the Mac could read it. NOOK_BRIDGE_TOKEN still works, for sessions started before.
$env{NOOK_BRIDGE_TOKEN} = token_from_file() if $env{NOOK_BRIDGE_TOKEN} eq '';

while (my $line = <STDIN>) {
    chomp $line;
    next if $line =~ /^\s*$/;
    my $message = eval { $json->decode($line) };
    next unless ref($message) eq 'HASH';
    my $method = (defined $message->{method} && !ref($message->{method})) ? $message->{method} : '';
    # A tool call may wait for your approval in the notch; everything else is quick.
    my $timeout = $method eq 'tools/call' ? 900 : 15;
    $env{NOOK_BRIDGE_TOKEN} = token_from_file() if $env{NOOK_BRIDGE_TOKEN} eq '';
    my $reply = ask_nook($json->encode({ agent => $agent, cwd => $cwd, env => \%env, message => $message }) . "\n", $timeout);
    next unless exists $message->{id};
    if ($reply ne '') { print $reply, "\n"; }
    else { print $json->encode(offline($message)), "\n"; }
}
exit 0;

sub token_from_file {
    my $path = $ENV{NOOK_BRIDGE_TOKEN_FILE};
    return '' unless defined $path && $path ne '' && open(my $fh, '<', $path);
    local $/;
    my $token = <$fh>;
    close $fh;
    $token = '' unless defined $token;
    $token =~ s/\s+\z//;
    return $token;
}

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
"#;

/// The port this computer's remote bridge listens on (127.0.0.1), set by the app once it listens; 0 while it does not.
static LOCAL_PORT: AtomicU16 = AtomicU16::new(0);

pub fn set_local_port(port: u16) {
    LOCAL_PORT.store(port, Ordering::SeqCst);
}

pub fn local_port() -> Option<u16> {
    Some(LOCAL_PORT.load(Ordering::SeqCst)).filter(|p| *p != 0)
}

pub fn script_path(home: &str) -> String {
    format!("{}/.nook/nook-mcp", home.trim_end_matches('/'))
}

/// Under `~/.nook`, which only that user may enter; short, because a socket path has a low limit.
pub fn socket_path(home: &str, run: &str) -> String {
    format!("{}/.nook/b-{}.sock", home.trim_end_matches('/'), &run.to_lowercase()[..8.min(run.len())])
}

/// The file that holds a session's token on that machine, under `~/.nook` (0700) like the socket.
pub fn token_path(home: &str, run: &str) -> String {
    format!("{}/.nook/bridge-tokens/{}", home.trim_end_matches('/'), run.to_lowercase())
}

/// The ssh arguments that carry the session's socket to this computer's port.
pub fn forward(socket: &str, port: u16) -> Vec<String> {
    vec!["-o".into(), "StreamLocalBindUnlink=yes".into(), "-R".into(), format!("{socket}:127.0.0.1:{port}")]
}

/// Puts the script on the machine and answers with `$HOME`, or fails when its Perl lacks what the script needs.
pub fn setup_command() -> String {
    let encoded = base64::engine::general_purpose::STANDARD.encode(SCRIPT);
    format!(
        r#"mkdir -p "$HOME/.nook" && chmod 700 "$HOME/.nook" && printf %s '{encoded}' | {{ base64 -d 2>/dev/null || base64 -D; }} > "$HOME/.nook/nook-mcp" && chmod 755 "$HOME/.nook/nook-mcp" && {{ find "$HOME/.nook/bridge-tokens" -type f -mtime +7 -exec rm -f {{}} + 2>/dev/null; true; }} && perl -MJSON::PP -MIO::Socket::UNIX -e 1 && printf %s "$HOME""#
    )
}

/// Writes the token read from stdin to `file`, 0600 in a 0700 folder, replaced in one step. The token is never an
/// argument, so it never shows up in the machine's process list.
pub fn token_writer(file: &str) -> Vec<String> {
    let script =
        r#"IFS= read -r t; umask 077; d=${1%/*}; mkdir -p "$d" && chmod 700 "$d" && printf '%s\n' "$t" > "$1.$$" && mv -f "$1.$$" "$1""#;
    vec!["-c".into(), script.into(), "nook-token".into(), file.into()]
}

/// Whether an agent on another machine may use `tool`. Everything that acts on this computer or in your name stays out.
pub fn allows(tool: BridgeTool) -> bool {
    use BridgeTool::*;
    match tool {
        BrowserOpen | BrowserRead | BrowserScreenshot | BrowserSnapshot | BrowserClick | BrowserType | BrowserWaitFor | RenderPage
        | SessionRead => true,
        WorkspaceInfo
        | TerminalRun
        | TerminalRead
        | TerminalList
        | TerminalStop
        | OrchestratorCapabilities
        | DelegateTask
        | TaskStatus
        | TaskWait
        | TaskCancel
        | PullRequestCreate
        | WatchPullRequest
        | GetPullRequestStatus
        | SessionList
        | SessionStart
        | SessionSend
        | SessionWait
        | SessionSearch
        | SessionOrganize
        | SessionQuestions
        | SessionSuggest
        | DeviceList
        | DeviceOpen
        | DeviceScreenshot
        | DeviceClose
        | ScheduleTask
        | ListScheduledTasks
        | UpdateScheduledTask
        | RunScheduledTaskNow
        | RequestSecret
        | NookTools
        | NookUse
        | NookChatList
        | NookChatRead
        | NookChatSend
        | ChatList
        | ChatRead
        | ChatSend
        | TakeOverScreen => false,
    }
}

/// `session_read` from another machine: its own session only, for what a handoff left out.
pub fn may_read(session: Option<&str>, caller: &str) -> bool {
    session.is_some_and(|s| s.trim().eq_ignore_ascii_case(caller.trim()))
}

/// Constant-time token check, matching `BridgeIdentity.matches` on the Mac.
pub fn matches_token(expected: Option<&str>, got: &str) -> bool {
    let Some(expected) = expected else { return false };
    if expected.is_empty() || expected.len() != got.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in expected.bytes().zip(got.bytes()) {
        diff |= a ^ b;
    }
    diff == 0
}

pub const REFUSAL: &str = "This session runs on another machine: this Nook tool only works for sessions on the user's computer. Run commands in your own shell there.";

pub const INSTRUCTIONS: &str = "You are running on another machine over SSH, and the user watches you in Nook on their computer. Through the `nook` MCP tools you can open pages in Nook's browser on that computer with browser_open and check them with browser_read, browser_snapshot or browser_screenshot; localhost there is the user's computer, not this machine. render_page shows the user a page in your session, and session_read reads your own session. Nook's other tools work only for sessions on the user's computer: run commands, dev servers and git in your own shell here.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_browser_a_page_and_its_own_session() {
        assert!(allows(BridgeTool::BrowserOpen));
        assert!(allows(BridgeTool::RenderPage));
        assert!(!allows(BridgeTool::TerminalRun));
        assert!(!allows(BridgeTool::SessionStart));
        assert!(!allows(BridgeTool::RequestSecret));
        assert!(may_read(Some(" ABCD "), "abcd"));
        assert!(!may_read(Some("other"), "abcd"));
        assert!(!may_read(None, "abcd"));
        assert!(matches_token(Some("secret-token"), "secret-token"));
        assert!(!matches_token(Some("secret-token"), "secret-tokeN"));
        assert!(!matches_token(Some(""), ""));
        assert!(!matches_token(None, "secret-token"));
    }

    #[test]
    fn paths_and_forwarding() {
        assert_eq!(socket_path("/home/me/", "ABCDEF12-3456"), "/home/me/.nook/b-abcdef12.sock");
        assert_eq!(token_path("/home/me", "ABC"), "/home/me/.nook/bridge-tokens/abc");
        assert_eq!(forward("/h/.nook/b-1.sock", 4567), vec!["-o", "StreamLocalBindUnlink=yes", "-R", "/h/.nook/b-1.sock:127.0.0.1:4567"]);
        assert!(SCRIPT.starts_with("#!/usr/bin/perl"));
        assert!(SCRIPT.contains("NOOK_BRIDGE_SOCK"));
        let setup = setup_command();
        let encoded = setup.split('\'').nth(1).unwrap();
        assert_eq!(base64::engine::general_purpose::STANDARD.decode(encoded).unwrap(), SCRIPT.as_bytes());
    }
}
