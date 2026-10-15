import SwiftUI

/// One line in "Today": something that needs you now.
struct TodayItem: Identifiable {
    enum Target { case card(CardScene), agent(String), action(() -> Void), none }
    var id: String = UUID().uuidString
    var title: String
    var subtitle: String
    var action: String
    var color: Color
    var target: Target
}

enum Greeting {
    static func quiet() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 0..<6: salutation = tr("greeting.night")
        case 6..<12: salutation = tr("greeting.morning")
        case 12..<18: salutation = tr("greeting.afternoon")
        default: salutation = tr("greeting.evening")
        }
        return tr("greeting.quiet", salutation)
    }

    static func line(count: Int) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 0..<6: salutation = tr("greeting.night")
        case 6..<12: salutation = tr("greeting.morning")
        case 12..<18: salutation = tr("greeting.afternoon")
        default: salutation = tr("greeting.evening")
        }
        let words = [
            tr("greeting.words.zero"),
            tr("greeting.words.one"),
            tr("greeting.words.two"),
            tr("greeting.words.three"),
            tr("greeting.words.four"),
            tr("greeting.words.five")
        ]
        let what = count < words.count ? words[count] : tr("greeting.words.many", count)
        return tr("greeting.line", salutation, what)
    }
}
