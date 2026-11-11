# Scenarios

A scenario shows one behavior in the real app: Nook's own `WorkspaceManager`, `AgentProcess`, stream parsing and the
main window's views (`WorkspaceView`, with the real `NookTheme`), with a replay agent standing in for the model. A run
costs nothing and plays the same way every time. Use one as the proof of a fix: it fails on the base commit and passes
on the fix. The idea and the shape come from t3code's scenarios (`docs/operations/scenarios.md` there).

Scenarios live in [`apps/macos/Scenarios`](../apps/macos/Scenarios):

- `Cases/`: the scenarios, one test per file.
- `Harness/`: the fixture (`nook`, `screen`, `app`, `expect`), the report, and the guards.
- `ReplayAgent/`: the replay agent, built as a `claude` program.
- `Recordings/`: what it plays, one `.jsonl` per recording.
- `scenarios.yml`: the `NookScenarios` and `NookReplayAgent` targets and the `NookScenarios` scheme, included from
  `apps/macos/project.yml`.

## Write one

```swift
final class ReplayTurnStreams: Scenario {
    func testReplayTurnStreams() throws {
        try scenario("A replayed turn streams a reply, shows its tool calls, and finishes") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let session = try nook.session(project: project, title: "Short tour",
                                                 messages: ["Give me a short tour"], wait: false)
            try nook.open(session)

            let stop = screen.button("Stop")
            try expect(screen.text("The project has a single math module")).toBeVisible()
            try expect(stop).toBeVisible()
            try app.screenshot("streaming")

            try expect(screen.text("This turn is a replay")).toBeVisible(timeout: 30)
            try expect(stop).toBeHidden()
            try app.screenshot("finished")
        }
    }
}
```

The fixture:

- `nook.project(name, files:)` makes a git repository in the scenario home. A file's content is a `String`, or `Data`
  for a binary file.
- `nook.session(project:, title:, messages:, recording:, wait:)` starts a Claude Code session through
  `WorkspaceManager.start`, the path `session_start` and `nook start` take, and plays one replayed turn per message.
  With `wait: false` it returns while the first turn still runs. `recording` picks the recording (the session's model);
  the default is `showcase`. It fails the scenario as "could not run" unless the session's process is the replay agent.
- `nook.send(session, text, wait:)` sends a message as the composer does.
- `nook.open(session)` hosts the main window's content at 1240 × 800 in a window that is never on screen, on the
  Agents tab with that session open.
- `screen.text("…")`, `screen.button("Stop")`, `screen.labelled("…")` find elements in the window's accessibility
  tree: what VoiceOver reads. `.first` picks the first of several. `.tap()` presses one as VoiceOver does
  (`accessibilityPerformPress`), `.fill("…")` types into a text field or text view.
- `expect(locator).toBeVisible()`, `.toBeHidden()`, `.toHaveCount(n)` wait up to a timeout (15 s by default).
- `app.screenshot("label")` writes `NN-label.png` to the scenario's results. A proof pairs base and head captures by
  label, so take one where the bug shows. A failing scenario gets a `failure` capture and a dump of the tree by itself.

Only `expect` decides that the behavior is broken (`failed`). A control that cannot be found to tap, a session that
does not start, a turn that fails, or a guard that refused something means the scenario could not run (`error`), which
says nothing about the behavior. Assert on the thing the bug breaks, and add an `expect` before it that shows the
scenario got there (the turn's reply is on screen), so a broken setup does not pass for the bug.

Write one test per file: a proof runs one scenario and needs exactly one result.

Scenarios are synchronous: they wait by turning the main run loop (`ScenarioClock`), which runs the app's own tasks
and SwiftUI's updates meanwhile. An `async` test crashed the test process as soon as SwiftUI's accessibility tree was
read, because that runs other main-actor work in the middle of the test's own task.

### Recordings

The replay agent speaks the part of Claude Code's `-p --input-format stream-json --output-format stream-json` that
Nook reads. For each message it plays the next turn of the recording: a `system` init line, what the recording holds,
and a `result` line. A recording is one JSON object per line (`//` lines are comments):

```jsonl
{"replay":"text","text":"Let me look at the logo first.","ms":30}
{"replay":"tool","id":"toolu_logo_{{turn}}","name":"Read","input":{"file_path":"{{cwd}}/Assets/logo.png"},"result":"[image]","ms":400}
{"replay":"turn"}
{"replay":"text","text":"The second turn."}
```

- `text` streams as deltas (`chunk` characters every `ms`), then the whole assistant message, as Claude Code does.
- `tool` is a `tool_use`, then after `ms` its `tool_result` (`"error": true` for a failed one).
- `sleep` waits `ms`. `turn` starts the next turn. Any other object goes out as is: a raw stream-json line, such as a
  `control_request` for an approval.
- `{{cwd}}`, `{{session_id}}`, `{{model}}`, `{{turn}}` and `{{uuid}}` are filled in.

A conversation keeps its turn count across processes (by session id), so a resumed session goes on where it was. The
replay agent answers every `control_request` with success, and an `interrupt` ends the turn as stopped.

## Run

```sh
./scripts/scenarios.sh                       # all of them
./scripts/scenarios.sh ReplayTurnStreams     # one, by class name
```

It builds the `NookScenarios` scheme with `./scripts/xcode.sh` (the build stays in `.build/xcode`) and runs it. Results
land in `.scratch/scenarios/out`: `report.json`, `summary.md`, `xcodebuild.log`, and per scenario
`results/<name>/result.json` with its screenshots. Exit 0 when all passed, 1 when one failed, 2 when one could not run.
The first build compiles the app's sources a second time (into the test bundle) and takes several minutes.

Run one at a time per checkout: a run recreates the checkout's scenario home and output. Use a second worktree for a
second run.

## Prove a fix

```sh
./scripts/prove-scenario.sh ViewedImageThumbnail --base 37f047b9 [--head HEAD]
```

It runs the scenario on both commits and writes `.scratch/scenarios/prove/proof.json` (`failsOnBase`, `passesOnHead`,
`baseSha`, `headSha`, `verdict`, each side's steps and captures) and `proof.md`, a table of base and head screenshots
for a pull request description. It exits 0 only when the scenario fails on base and passes on head, 1 when it ran and did
not prove the fix (it passes on base too, or still fails on head), and 2 when it could not run on a side.

The scenario and the harness always come from your checkout; only the app comes from the commit under test. Your clean
`HEAD` runs in place. Any other commit gets a temporary worktree under `.build/prove/<sha>`, with `apps/macos/Scenarios`,
`scripts/xcode.sh` and `scripts/scenarios.sh` laid over it and `include: [Scenarios/scenarios.yml]` added to its
`project.yml`. It is built with its own copy of `./scripts/xcode.sh` and removed afterwards, build and all (several GB:
check `df -h /` first). So a new scenario can prove a fix against a base that predates it, as long as the fixture's
calls (`WorkspaceManager.start`, `send`, `NotchViewModel.windowTab`/`selectedAgentID`, `WorkspaceView`) exist there.

## How it stays off your Mac

This Mac is in use while scenarios run, and the user's own Nook runs beside them. The test process:

- Never launches Nook.app. The `NookScenarios` bundle has no app host: it compiles the app's sources (all of the Nook
  target but `App/main.swift`) and runs them in the test process. `AppModel` is made but never started: no notch, no
  hook socket, no connectors, no window controllers.
- Has the scenario home as its home folder (`CFFIXED_USER_HOME`, set by `scenarios.sh`). Everything the app derives from
  the home folder (Application Support, `~/.nook`, `~/.claude`, `~/.codex`) lands in `.scratch/scenarios/home`.
  `NookPaths.supportDirectory` points there too, `UserDefaults.standard` is a file in it, and the harness refuses to run
  when the home is not that folder.
- Gives agents `HOME` = the scenario home and a `PATH` with only the replay agent's folder and the system's, without
  the user's API keys. `WorkspaceManager.executable` is the replay agent for every agent, and each session checks that
  its process really is.
- Never touches the Keychain: `ScenarioGuards.c` defines `SecItem*` in the bundle, which wins over the system's at link
  time; they find nothing and store nothing.
- Refuses to start a real coding agent: `posix_spawn` (C) and `Process` (Swift) refuse `claude`, `codex`, `gemini` and
  the other agents, and shells told to run one; only the replay agent may run under that name. A refusal fails the
  scenario as "could not run".
- Shows no window and takes no focus: the activation policy is `.prohibited`, the hosted window sits far outside every
  screen and is never ordered in, and putting any window in front, activating, opening a URL or an app, and AppleScript
  are refused and written to the report.

## What a scenario cannot cover

- The notch, several windows, menus, the menu bar, and anything that needs the real window server (focus, hover,
  drag and drop, Quick Look). The window is never on screen.
- Real input. Elements are pressed through accessibility; SwiftUI buttons do not fire from synthesized mouse events
  in a window that is not on screen.
- Agent behavior beyond what the Claude Code replay says: Codex, Gemini CLI, ACP agents and the others speak other
  protocols, and a recording only holds what Claude Code would print. Provider-specific behavior needs a replay of its
  own.
- State no recording or fixture call can make, such as a usage limit, a real pull request, or a Settings choice that
  needs the Keychain.
- Timing and performance. Replay streaming is simulated and the window draws only when the harness asks.
