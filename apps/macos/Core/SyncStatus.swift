import Foundation

/// The calm line that says whether what Nook shows is current: when it last synced, whether the Mac is offline, and
/// how many messages wait to be sent. One text for every surface (main window, notch, menu bar).
enum NookSyncStatus {
    /// "Last synced 12 min ago", "Offline. Showing what Nook saved 12 min ago." or "Not synced yet".
    static func text(lastSynced: Date?, offline: Bool, queued: Int = 0, now: Date = Date()) -> String {
        var parts: [String] = []
        if let lastSynced {
            let ago = NookDates.ago(lastSynced, now: now)
            parts.append(offline ? tr("sync.offline.since", ago) : tr("sync.last", ago))
        } else {
            parts.append(offline ? tr("sync.offline") : tr("sync.never"))
        }
        if queued > 0 { parts.append(trPlural("sync.queued", count: queued)) }
        return parts.joined(separator: " · ")
    }
}

extension I18n {
    /// The plural category of `count` in `language`: "one" or "other". English, Dutch, German and Spanish use "one" for
    /// exactly 1; French also for 0.
    static func pluralCategory(_ count: Int, language: AppLanguage) -> String {
        switch language {
        case .fr: return (count == 0 || count == 1) ? "one" : "other"
        default: return count == 1 ? "one" : "other"
        }
    }
}

/// `key.one` or `key.other` for `count`, in the app's language, with the count filled in for `%d`/`%ld`.
func trPlural(_ key: String, count: Int) -> String {
    let language = I18n.shared.currentLanguage
    let category = I18n.pluralCategory(count, language: language)
    return I18n.text("\(key).\(category)", [count], for: language)
}
