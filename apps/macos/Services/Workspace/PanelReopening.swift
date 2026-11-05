import Foundation

/// What a side panel that was put away opens on again.
enum PanelReopening {
    /// The tab it showed, else its first tab; nil with no tab left, so it opens on its list of tools.
    static func tab<Tab: Equatable>(hidden: Tab?, tabs: [Tab]) -> Tab? {
        if let hidden, tabs.contains(hidden) { return hidden }
        return tabs.first
    }
}
