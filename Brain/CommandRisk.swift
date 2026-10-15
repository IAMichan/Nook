import Foundation

struct CommandAssessment {
    enum Level { case safe, review, danger }
    var level: Level
    var title: String
    var note: String
}

/// Rough assessment of a shell command an agent wants to run. This is a safety net, not a guarantee: it never approves
/// anything by itself, it only decides how loudly to warn. Anything that is not clearly harmless requires your review.
///
/// The command is split into its parts (`a; b | c`) and words, the way a shell would, so spacing, flag order or quoting
/// tricks (`rm -r -f /`, `curl x|sh`) do not hide what it does.
enum CommandRisk {
    // MARK: Lists

    private static let safeCommands: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo", "grep", "rg", "which", "date",
        "whoami", "tree", "file", "stat", "du", "df", "uname", "less", "more", "sort", "uniq", "diff"
    ]
    private static let safeGit: Set<String> = ["status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "python", "python3", "perl", "ruby", "node", "osascript"]
    /// Programs that run something else from a string: what they do cannot be judged here.
    private static let runsCode: Set<String> = ["eval", "exec", "source", "."]
    private static let wrappers: Set<String> = ["env", "command", "nohup", "time", "nice", "caffeinate", "builtin"]
    /// Programs that print, copy or send file contents.
    private static let fileReaders: Set<String> = [
        "cat", "head", "tail", "less", "more", "cp", "scp", "rsync", "base64", "xxd", "hexdump", "strings", "open", "tar", "zip",
        "ditto", "mv", "curl", "wget", "nc", "pbcopy", "bat", "od", "sed", "awk", "sqlite3", "plutil"
    ]

    private static let dangerousPrograms: [String: String] = [
        "sudo": "Runs with administrator rights",
        "su": "Switches to another user",
        "doas": "Runs with administrator rights",
        "mkfs": "Formats a disk",
        "newfs": "Formats a disk",
        "fdisk": "Changes disk partitions",
        "dd": "Writes raw data to a disk or file",
        "shutdown": "Shuts down the Mac",
        "reboot": "Restarts the Mac",
        "halt": "Stops the Mac",
        "csrutil": "Changes system protection",
        "nvram": "Changes firmware settings",
        "spctl": "Changes app security settings",
        "kextload": "Loads a kernel extension",
        "systemsetup": "Changes system settings",
        "dscl": "Changes user accounts",
        "passwd": "Changes a password",
        "crontab": "Schedules commands to run later",
        "osascript": "Runs AppleScript, which can control any app"
    ]

    /// Places whose contents are secrets: reading or copying them is treated as dangerous.
    private static let secretPaths = [
        ".ssh", "id_rsa", "id_ed25519", "id_ecdsa", ".aws/credentials", ".netrc", ".npmrc", ".pypirc", ".docker/config.json",
        ".kube/config", ".gnupg", "keychain", ".env", ".git-credentials", ".config/gh/hosts.yml", "library/cookies",
        ".claude.json", ".codex/auth.json", "login.keychain"
    ]
    /// Files that run at login or configure the shell: writing them is a way to persist.
    private static let persistencePaths = [
        ".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile", "launchagents", "launchdaemons", "/etc/", ".ssh/authorized_keys"
    ]

    // MARK: Assessment

    static func assess(_ command: String) -> CommandAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return review("Runs a command on your Mac · please review") }
        let lower = trimmed.lowercased()

        if lower.contains(":(){") || lower.contains(":() {") {
            return danger("Starts processes until the Mac freezes")
        }

        let segments = split(trimmed)
        var notes: [String] = []
        var previousProgram: String?

        for segment in segments {
            let words = programWords(segment.words)
            guard let program = words.first.map(baseName) else { previousProgram = nil; continue }
            let arguments = Array(words.dropFirst())
            let lowerArguments = arguments.map { $0.lowercased() }

            // Downloaded text straight into an interpreter.
            if segment.pipedFrom, let previous = previousProgram, ["curl", "wget", "fetch", "cat", "base64", "echo", "printf"].contains(previous),
               shells.contains(program) {
                return danger("Runs code straight from \(previous == "curl" || previous == "wget" ? "the internet" : "text") without saving it first")
            }
            if let reason = dangerousPrograms[program] ?? (program.hasPrefix("mkfs") ? "Formats a disk" : nil) {
                return danger(reason)
            }
            if let reason = dangerousUse(program, arguments, lowerArguments) {
                return danger(reason)
            }
            if fileReaders.contains(program), touchesSecrets(lowerArguments) {
                return danger("Reads or copies passwords, keys or login data")
            }
            if let target = segment.redirectTarget?.lowercased() {
                if target.hasPrefix("/dev/disk") || target.hasPrefix("/dev/rdisk") { return danger("Writes directly to a disk") }
                if persistencePaths.contains(where: { target.contains($0) }) { return danger("Changes a file that runs at login") }
            }
            if let note = reviewNote(program, arguments, lowerArguments) { notes.append(note) }
            previousProgram = program
        }

        if lower.contains("$(") || lower.contains("`") || lower.contains("<(") {
            notes.append("Builds part of the command from another command")
        }
        if segments.count == 1, notes.isEmpty, isSimpleReadOnly(segments[0]) {
            return CommandAssessment(level: .safe, title: "", note: "")
        }
        return review(notes.first ?? "Runs a command on your Mac · please review")
    }

    private static func danger(_ note: String) -> CommandAssessment {
        CommandAssessment(level: .danger, title: "This command is risky. Are you sure?", note: note)
    }

    private static func review(_ note: String) -> CommandAssessment {
        CommandAssessment(level: .review, title: "", note: note)
    }

    // MARK: Rules

    private static func dangerousUse(_ program: String, _ arguments: [String], _ lower: [String]) -> String? {
        let flags = shortFlags(arguments)
        switch program {
        case "rm":
            let recursive = flags.contains("r") || flags.contains("R") || lower.contains("--recursive")
            let force = flags.contains("f") || lower.contains("--force")
            let targets = arguments.filter { !$0.hasPrefix("-") }
            if recursive && targets.contains(where: isBroadTarget) { return "Deletes your whole disk, home folder or everything here" }
            if recursive && force { return "Deletes folders without asking, cannot be undone" }
        case "chmod", "chown", "chgrp":
            let recursive = flags.contains("R") || lower.contains("--recursive")
            if recursive && arguments.contains(where: isBroadTarget) { return "Changes permissions of your whole disk or home folder" }
        case "git":
            guard let sub = lower.first else { return nil }
            let rest = Array(lower.dropFirst())
            if sub == "push", rest.contains(where: { $0 == "-f" || $0.hasPrefix("--force") || $0.hasPrefix("+") || $0.contains(":+") || $0 == "--mirror" || $0 == "--delete" || $0 == "-d" }) {
                return "Overwrites or deletes history on the server"
            }
            if sub == "reset", rest.contains("--hard") { return "Throws away uncommitted work" }
            if sub == "clean", rest.contains(where: { $0.hasPrefix("-") && $0.contains("f") }) { return "Deletes untracked files" }
            if sub == "checkout" || sub == "restore", rest.contains("."), rest.contains("--") || sub == "restore" { return "Throws away uncommitted work" }
            if sub == "branch", arguments.contains("-D") || rest.contains("--force") && rest.contains(where: { $0 == "-d" || $0 == "--delete" }) {
                return "Deletes a branch that may not be merged"
            }
            if sub == "filter-branch" || sub == "filter-repo" { return "Rewrites the whole history" }
            if sub == "stash", rest.first == "clear" || rest.first == "drop" { return "Throws away stashed work" }
        case "diskutil":
            if lower.contains(where: { ["erase", "erasedisk", "erasevolume", "partitiondisk", "zerodisk", "secureerase", "reformat", "apfs"].contains($0) }) {
                return "Erases or changes a disk"
            }
        case "launchctl":
            if lower.contains(where: { ["unload", "remove", "bootout", "disable", "load", "bootstrap"].contains($0) }) { return "Changes background services" }
        case "defaults":
            if lower.first == "delete" { return "Deletes app or system settings" }
        case "security":
            if lower.contains(where: { $0.hasPrefix("dump-keychain") || $0.hasPrefix("find-generic-password") || $0.hasPrefix("find-internet-password") || $0.hasPrefix("delete-") || $0 == "export" }) {
                return "Reads or deletes passwords from the keychain"
            }
        case "killall", "pkill":
            if lower.contains(where: { ["finder", "dock", "windowserver", "loginwindow", "systemuiserver"].contains($0) }) { return "Stops part of macOS" }
        case "find":
            if lower.contains("-delete") && arguments.contains(where: isBroadTarget) { return "Deletes files across your disk or home folder" }
        default:
            break
        }
        return nil
    }

    private static func reviewNote(_ program: String, _ arguments: [String], _ lower: [String]) -> String? {
        if shells.contains(program) || runsCode.contains(program) { return "Runs a script or code · please review what it does" }
        if program == "rm" || program == "rmdir" || program == "unlink" || program == "trash" { return "Deletes files" }
        if program == "mv" { return "Moves or renames files" }
        if program == "git" && lower.first == "push" { return "Pushes changes online" }
        if ["curl", "wget", "fetch", "scp", "rsync", "ftp", "sftp", "nc", "ncat", "ssh"].contains(program) { return "Connects to another computer or the internet" }
        if ["printenv", "env", "set", "export"].contains(program) && arguments.isEmpty { return "Shows environment variables, which can include keys" }
        if lower.contains("install") || lower.contains("add") || ["brew", "npm", "pnpm", "yarn", "pip", "pip3", "gem", "cargo"].contains(program) {
            return "Installs packages · usually reversible"
        }
        if program == "chmod" && lower.contains(where: { $0.hasSuffix("777") || $0 == "+s" || $0.contains("u+s") }) { return "Gives broad permissions to a file" }
        return nil
    }

    private static func isSimpleReadOnly(_ segment: Segment) -> Bool {
        guard segment.redirectTarget == nil else { return false }
        let words = programWords(segment.words)
        guard let first = words.first.map(baseName) else { return false }
        let lower = words.dropFirst().map { $0.lowercased() }
        if first == "git" {
            guard let sub = lower.first else { return false }
            if safeGit.contains(sub) { return true }
            if sub == "branch" { return lower.dropFirst().allSatisfy { ["-a", "-v", "-vv", "-r", "--list", "--show-current", "-l"].contains($0) } }
            if sub == "remote" {
                let rest = Array(lower.dropFirst())
                return rest.isEmpty || rest == ["-v"] || ["show", "get-url"].contains(rest[0])
            }
            return false
        }
        if first == "find" {
            let writes = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
            return !lower.contains(where: { writes.contains($0) })
        }
        return safeCommands.contains(first)
    }

    // MARK: Parsing

    struct Segment {
        var words: [String] = []
        /// Its input comes from the previous part through a pipe.
        var pipedFrom = false
        /// File written by `>` or `>>`, if any.
        var redirectTarget: String?
    }

    /// Splits a command line into parts and words, honouring quotes and backslashes like a shell.
    static func split(_ line: String) -> [Segment] {
        var segments: [Segment] = []
        var current = Segment()
        var word = ""
        var hasWord = false
        var quote: Character?
        var escape = false
        var expectRedirect = false
        let characters = Array(line)
        var index = 0

        func endWord() {
            guard hasWord else { return }
            if expectRedirect {
                current.redirectTarget = word
                expectRedirect = false
            } else {
                current.words.append(word)
            }
            word = ""
            hasWord = false
        }
        func endSegment(piped: Bool) {
            endWord()
            if !current.words.isEmpty || current.redirectTarget != nil { segments.append(current) }
            current = Segment()
            current.pipedFrom = piped
        }

        while index < characters.count {
            let character = characters[index]
            defer { index += 1 }
            if escape { word.append(character); hasWord = true; escape = false; continue }
            if character == "\\" && quote != "'" { escape = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
                hasWord = true
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                hasWord = true
            case " ", "\t":
                endWord()
            case "\n", ";":
                endSegment(piped: false)
            case "&":
                if index + 1 < characters.count, characters[index + 1] == "&" { index += 1 }
                endSegment(piped: false)
            case "|":
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    index += 1
                    endSegment(piped: false)
                } else {
                    endSegment(piped: true)
                }
            case ">":
                // `2>&1` and `>&2` duplicate a stream; they do not write a file.
                if index + 1 < characters.count, characters[index + 1] == "&" {
                    index += 1
                    while index + 1 < characters.count, characters[index + 1].isNumber { index += 1 }
                    if hasWord, word.allSatisfy(\.isNumber) { word = ""; hasWord = false }
                    continue
                }
                if hasWord, word.allSatisfy(\.isNumber) { word = ""; hasWord = false } else { endWord() }
                if index + 1 < characters.count, characters[index + 1] == ">" { index += 1 }
                expectRedirect = true
            default:
                word.append(character)
                hasWord = true
            }
        }
        endSegment(piped: false)
        return segments
    }

    /// The words from the actual program on: skips `FOO=bar`, and wrappers like `env`, `nohup` or `time`.
    private static func programWords(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            if first.contains("="), !first.hasPrefix("-"), first.first.map({ $0.isLetter || $0 == "_" }) == true {
                rest = rest.dropFirst()
            } else if wrappers.contains(baseName(first)) {
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }
            } else {
                break
            }
        }
        return Array(rest)
    }

    private static func baseName(_ program: String) -> String {
        (program.split(separator: "/").last.map(String.init) ?? program).lowercased()
    }

    /// Letters of all short flags: `-rf -v` → {r, f, v}.
    private static func shortFlags(_ arguments: [String]) -> Set<Character> {
        var flags = Set<Character>()
        for argument in arguments where argument.hasPrefix("-") && !argument.hasPrefix("--") {
            flags.formUnion(argument.dropFirst())
        }
        return flags
    }

    private static func isBroadTarget(_ raw: String) -> Bool {
        let target = raw.trimmingCharacters(in: .whitespaces)
        let broad: Set<String> = ["/", "/*", "~", "~/", "~/*", "*", ".", "./", "./*", "..", "../", "$home", "$home/", "${home}", "/users", "/system", "/library", "/applications", "/usr", "/etc", "/var", "/private"]
        return broad.contains(target.lowercased()) || target.hasPrefix("/") && target.split(separator: "/").count == 1
    }

    private static func touchesSecrets(_ lowerArguments: [String]) -> Bool {
        lowerArguments.contains { argument in
            guard !argument.hasPrefix("-") || argument.contains("/") else { return false }
            let components = argument.split(separator: "/").map(String.init)
            if components.contains(where: { $0 == ".env" || $0.hasPrefix(".env.") && !$0.hasSuffix(".example") && !$0.hasSuffix(".sample") }) { return true }
            return secretPaths.contains { $0 != ".env" && argument.contains($0) }
        }
    }
}
