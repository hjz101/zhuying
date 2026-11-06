import Foundation

/// Counts time with readable prose visible. Background/provider stalls never
/// count as reading, and a dismissed invitation stays dismissed for this book.
@MainActor final class ReadingShelfPrompt {
    private let defaults: UserDefaults
    private let key: String
    private var elapsed: [String: TimeInterval] = [:]
    private var previous: (bookID: String, uptime: TimeInterval, active: Bool)?

    init(defaults: UserDefaults, key: String) { self.defaults = defaults; self.key = key }

    func sample(bookID: String, active: Bool, eligible: Bool, uptime: TimeInterval) -> Bool {
        if let previous, previous.bookID == bookID, previous.active, eligible {
            let delta = uptime - previous.uptime
            if delta > 0 && delta <= 5 { elapsed[bookID, default: 0] += delta }
        }
        previous = (bookID, uptime, active && eligible)
        guard active, eligible, elapsed[bookID, default: 0] >= 120 else { return false }
        var prompted = Set(defaults.stringArray(forKey: key) ?? [])
        guard prompted.insert(bookID).inserted else { return false }
        defaults.set(prompted.sorted(), forKey: key)
        return true
    }
}
