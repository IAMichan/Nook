import SwiftUI

extension SessionWorkbench {
    /// What the workbench does as things change around it: reading ahead the pull request it links, the browser of the
    /// session on screen, opening a diff a row asked for, the panels' focus, and its keys. `side`, `bottom`, `canDock` and
    /// `docked` are what the body worked out for this pass.
    func sessionEvents(_ content: some View, side: SessionTool, bottom: SessionTool, canDock: Bool, docked: Bool) -> some View {
        content
            // The pull request the conversation links last is the one you are likely to open: read it ahead, once the
            // session has settled in, so its link opens on the page at once.
            .task(id: outputs.pullRequest) {
                guard let url = outputs.pullRequest else { return }
                try? await Task.sleep(for: NookTheme.tabSettle)
                if !Task.isCancelled { app.prefetchPullRequestLink(url) }
            }
            .onChange(of: docked) { _, now in wasDocked = now }
            // After the frame with the new widths, so it starts from where the column stood.
            .onChange(of: chatSlide) { _, now in
                if now != 0 { withAnimation(NookTheme.reveal) { chatSlide = 0 } }
            }
            // Links, scripts and pages you open go to the browser of the session on screen.
            .onAppear { SessionBrowsers.shared.appeared(browserSession) }
            .onDisappear { SessionBrowsers.shared.disappeared(browserSession) }
            .onChange(of: browserSession) { old, new in
                SessionBrowsers.shared.disappeared(old)
                SessionBrowsers.shared.appeared(new)
            }
            .onChange(of: runID) { _, _ in
                diffSelection = nil
                consoleEventID = nil
                dropStaleSubThread()
            }
            .onAppear { dropStaleSubThread() }
            // A task, not onChange: it also runs for the workbench a row's card just opened, after the change above.
            .task(id: viewModel.sessionDiffToOpen) {
                guard let selection = viewModel.sessionDiffToOpen else { return }
                viewModel.sessionDiffToOpen = nil
                openDiff(selection)
            }
            .animation(NookTheme.reveal, value: bottom == .conversation)
            .onChange(of: bottom) { _, next in
                if SessionTool.panelTools.contains(next) { lastBottomTool = next.rawValue }
                panelTakesFocus = true
            }
            .onChange(of: side) { _, next in
                panelTakesFocus = true
                if next == .conversation { panelMaximized = false }
            }
            // The Changes tab put away: it opens on the branch again, not on the turn it last came from.
            .onChange(of: changesShown) { _, shown in
                if !shown { diffSelection = nil }
            }
            // The Terminal tab put away: the next time it opens it shows your own shells again.
            .onChange(of: consoleShown) { _, shown in
                if !shown { consoleEventID = nil }
            }
            // ⌘D: the Changes tab on the latest turn, or on the branch before there are turns; again to close it.
            .keyCommand("diff.toggle", enabled: usable(.changes)) {
                withAnimation(NookTheme.reveal) {
                    if changesShown {
                        putAway(.changes, in: viewModel.bottomTool == .changes ? .bottom : .side)
                    } else {
                        openDiff(TurnDiffSelection(turn: outputs.turns.last?.id ?? TurnDiffSelection.branch))
                    }
                }
            }
            // ⇧⌘T: the tab closed last comes back, in the panel it was in; the key goes on when there is none.
            .keyCommands(["panel.reopenClosed": reopenClosed])
            // ⌘J the terminal under the conversation, ⌥⌘B the side panel, ⌘W the tab of the panel with the keyboard.
            .keyCommands(["terminal.toggle": toggleTerminal,
                          // ⇧⌘B the session panel; without room for it the key goes on.
                          "sessionPanel.toggle": {
                              guard canDock else { return false }
                              toggleSessionPanel()
                              return true
                          },
                          "sidePanel.toggle": { viewModel.toggleSidePanel(); return true },
                          "tab.close": { closeFocusedTab() }])
    }
}
