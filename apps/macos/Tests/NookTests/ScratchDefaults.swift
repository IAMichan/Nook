import Foundation
import XCTest

extension XCTestCase {
    /// A defaults suite of its own for this test, kept in a temporary folder and gone again after it.
    ///
    /// A suite named after a fresh UUID left its plist in ~/Library/Preferences on every run, also after
    /// `removePersistentDomain` (cfprefsd writes the emptied domain later): about 3,750 files on one Mac by 2026-11-10.
    /// A suite name that is an absolute path keeps the file at that path instead.
    func scratchDefaults(_ prefix: String) -> UserDefaults {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = folder.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: name) else { fatalError("no defaults suite at \(name)") }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        return defaults
    }
}
