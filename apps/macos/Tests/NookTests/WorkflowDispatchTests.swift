import XCTest

/// Starting a workflow by hand from the Actions page: its trigger and inputs read from the file, and what is sent.
final class WorkflowDispatchTests: XCTestCase {
    func testAWorkflowWithoutDispatchCannotBeStarted() {
        XCTAssertNil(WorkflowDispatch.inputs("name: CI\non:\n  push:\n    branches: [main]\njobs:\n  test:\n    runs-on: ubuntu-latest\n"))
        XCTAssertNil(WorkflowDispatch.inputs("name: CI\non: push\n"))
        XCTAssertNil(WorkflowDispatch.inputs("name: no trigger\njobs: {}\n"))
    }

    func testTheShortFormsOfTheTrigger() {
        XCTAssertEqual(WorkflowDispatch.inputs("on: workflow_dispatch\n"), [])
        XCTAssertEqual(WorkflowDispatch.inputs("on: [push, workflow_dispatch]\n"), [])
        XCTAssertEqual(WorkflowDispatch.inputs("\"on\":\n  workflow_dispatch:\n  push:\n"), [])
        XCTAssertEqual(WorkflowDispatch.inputs("'on':\n  - push\n  - workflow_dispatch\n"), [])
        XCTAssertEqual(WorkflowDispatch.inputs("true:\n  workflow_dispatch: {}\n"), [])
        XCTAssertEqual(WorkflowDispatch.inputs("on: { push: {}, workflow_dispatch: {} }\n"), [])
        // The word only in a comment or under jobs does not count.
        XCTAssertNil(WorkflowDispatch.inputs("on:\n  push: # not workflow_dispatch\njobs:\n  workflow_dispatch:\n    runs-on: x\n"))
    }

    func testInputsInTheFilesOrderWithTheirKinds() throws {
        let file = """
        name: Release
        # Started by hand only.
        on:
          push:
            branches:
            - main
          workflow_dispatch:
            inputs:
              version:
                description: 'Version to release, e.g. 1.2.0'   # shown in the form
                required: true
              channel:
                description: "Which channel"
                type: choice
                default: beta
                options:
                  - stable
                  - beta
              dry-run:
                type: boolean
                default: true
              count:
                type: number
              target:
                type: environment
                required: false
              notes:
                description: |
                  Release notes,
                  in Markdown: with a # inside
              tags:
                type: choice
                options: [a, "b, c", 'd']
        jobs:
          release:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - name: Build
                run: make
        """
        let inputs = try XCTUnwrap(WorkflowDispatch.inputs(file))
        XCTAssertEqual(inputs.map(\.name), ["version", "channel", "dry-run", "count", "target", "notes", "tags"])
        XCTAssertEqual(inputs[0], WorkflowInput(name: "version", description: "Version to release, e.g. 1.2.0", required: true))
        XCTAssertEqual(inputs[1].kind, .choice)
        XCTAssertEqual(inputs[1].options, ["stable", "beta"])
        XCTAssertEqual(inputs[1].initialValue, "beta")
        XCTAssertEqual(inputs[1].description, "Which channel")
        XCTAssertEqual(inputs[2].kind, .boolean)
        XCTAssertEqual(inputs[2].initialValue, "true")
        XCTAssertEqual(inputs[3].kind, .number)
        XCTAssertEqual(inputs[4].kind, .environment)
        XCTAssertFalse(inputs[4].required)
        XCTAssertEqual(inputs[5].description, "Release notes,\nin Markdown: with a # inside")
        XCTAssertEqual(inputs[6].options, ["a", "b, c", "d"])
        XCTAssertEqual(inputs[6].initialValue, "a", "a choice without a default starts on its first option")
    }

    func testRequiredInputsMustBeFilled() {
        let inputs = [WorkflowInput(name: "version", required: true), WorkflowInput(name: "note"),
                      WorkflowInput(name: "force", required: true, kind: .boolean)]
        XCTAssertEqual(WorkflowDispatch.missing(inputs, values: ["version": "  "]), ["version"])
        XCTAssertEqual(WorkflowDispatch.missing(inputs, values: ["version": "1.0"]), [])
    }

    func testTheBodyGitHubExpects() {
        let inputs = [WorkflowInput(name: "version", required: true), WorkflowInput(name: "note"),
                      WorkflowInput(name: "force", kind: .boolean), WorkflowInput(name: "undeclared-in-values", defaultValue: "x")]
        let body = WorkflowDispatch.body(ref: "main", inputs: inputs, values: ["version": " 1.2 ", "note": "", "force": "true", "extra": "no"])
        XCTAssertEqual(body["ref"] as? String, "main")
        XCTAssertEqual(body["return_run_details"] as? Bool, true)
        XCTAssertEqual(body["inputs"] as? [String: String], ["version": "1.2", "force": "true", "undeclared-in-values": "x"],
                       "an empty optional input is left out, a value the workflow does not declare is not sent")
        XCTAssertNil(WorkflowDispatch.body(ref: "main", inputs: [], values: [:])["inputs"])
    }

    func testGitHubsAnswers() {
        XCTAssertEqual(WorkflowDispatch.runID(["workflow_run_id": 42, "html_url": "https://github.com/o/r/actions/runs/42"]), 42)
        XCTAssertNil(WorkflowDispatch.runID(nil))
        let content = Data("on: workflow_dispatch\n".utf8).base64EncodedString(options: .lineLength64Characters)
        XCTAssertEqual(WorkflowDispatch.fileText(["content": content, "encoding": "base64"]), "on: workflow_dispatch\n")
        XCTAssertEqual(WorkflowDispatch.branches([["name": "feature"], ["name": "main"]], defaultBranch: "main"), ["main", "feature"])
        XCTAssertEqual(WorkflowDispatch.filePath(repo: "o/r", path: ".github/workflows/ci.yml", ref: "fix/a b"),
                       "/repos/o/r/contents/.github/workflows/ci.yml?ref=fix%2Fa%20b")
    }
}
