import Foundation

/// Regular expressions compiled once and kept by pattern and options. Compiling a pattern costs far more than running
/// it, and many helpers build theirs from a name or run on every line, banner, page tag or keystroke. NSCache and
/// NSRegularExpression are both safe to share between threads.
enum RegexCache {
    private static let compiled: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 2_000
        return cache
    }()

    /// `pattern` compiled with `options`; nil when it is not a valid pattern.
    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)" as NSString
        if let known = compiled.object(forKey: key) { return known }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        compiled.setObject(regex, forKey: key)
        return regex
    }
}
