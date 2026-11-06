import Foundation

enum ReadingActivityKind: String, Codable, Sendable { case reading, listening }

/// Wall time places a session on the calendar; monotonic time measures its
/// duration. Clock changes and suspended gaps never create invented reading.
struct ReadingActivityClock {
    private var bookID: String?
    private var wall: Date?
    private var uptime: TimeInterval?
    private var interaction: TimeInterval = 0
    mutating func advance(bookID next: String?, active: Bool, interacted: Bool, wall now: Date, uptime tick: TimeInterval,
                          kind: ReadingActivityKind = .reading) -> ActivitySession? {
        let changedBook = next != bookID
        defer {
            bookID = active ? next : nil; wall = now; uptime = tick
            if interacted || changedBook { interaction = tick }
        }
        guard let bookID, let wall, let uptime else { interaction = tick; return nil }
        let delta = tick - uptime
        guard delta > 0, delta <= 15, abs(now.timeIntervalSince(wall) - delta) < 3 else { return nil }
        let credited = kind == .listening ? delta : max(0, min(tick, interaction + 60) - uptime)
        guard credited > 0 else { return nil }
        return .init(bookID: bookID, start: wall, seconds: credited, kind: kind)
    }
}
