import Foundation

/// Disposable LRU cache. A chapter larger than the quota may occupy it alone.
struct ChapterMemoryCache {
    private struct Entry { let document: ChapterDocument; let bytes: Int }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    let maximumCount: Int
    let maximumBytes: Int
    init(maximumCount: Int = 3, maximumBytes: Int = 4 * 1024 * 1024) {
        self.maximumCount = max(1, maximumCount); self.maximumBytes = max(1, maximumBytes)
    }
    var count: Int { entries.count }
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    subscript(id: String) -> ChapterDocument? {
        mutating get {
            guard let entry = entries[id] else { return nil }
            order.removeAll { $0 == id }; order.append(id)
            return entry.document
        }
        set {
            removeValue(forKey: id)
            guard let value = newValue else { return }
            entries[id] = .init(document: value, bytes: value.paragraphs.reduce(0) { $0 + $1.text.utf16.count * 2 })
            order.append(id)
            while entries.count > 1 && (entries.count > maximumCount || bytes > maximumBytes) {
                removeValue(forKey: order[0])
            }
        }
    }
    mutating func removeValue(forKey id: String) { entries.removeValue(forKey: id); order.removeAll { $0 == id } }
}
