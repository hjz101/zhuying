import Foundation
import Combine

@MainActor
final class ToolboxStore: ObservableObject {
    static let storageKey = "yueshan.toolbox.v1"
    static let limit = 4
    @Published private(set) var pinnedIDs: [String]
    private let defaults: UserDefaults
    private let knownIDs = Set(FeatureCatalog.all.map(\.id))
    var canAdd: Bool { pinnedIDs.count < Self.limit }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.storageKey) as? [String] {
            var seen = Set<String>()
            let ids = Set(FeatureCatalog.all.map(\.id))
            let valid = Array(stored.filter { ids.contains($0) && seen.insert($0).inserted }.prefix(Self.limit))
            pinnedIDs = !stored.isEmpty && valid.isEmpty ? FeatureCatalog.commonToolIDs : valid
        } else { pinnedIDs = FeatureCatalog.commonToolIDs }
    }
    @discardableResult func add(_ id: String) -> Bool {
        guard knownIDs.contains(id) else { return false }
        if pinnedIDs.contains(id) { return true }
        guard canAdd else { return false }
        pinnedIDs.append(id); persist(); return true
    }
    func remove(_ id: String) { pinnedIDs.removeAll { $0 == id }; persist() }
    @discardableResult func replace(_ id: String, with replacement: String) -> Bool {
        guard let index = pinnedIDs.firstIndex(of: id), knownIDs.contains(replacement) else { return false }
        if id == replacement { return true }
        guard !pinnedIDs.contains(replacement) else { return false }
        pinnedIDs[index] = replacement; persist(); return true
    }
    func move(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ pinnedIDs.indices.contains($0) }), (0...pinnedIDs.count).contains(destination) else { return }
        let moving = offsets.sorted().map { pinnedIDs[$0] }
        let remaining = pinnedIDs.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let target = destination - offsets.filter { $0 < destination }.count
        var result = remaining; result.insert(contentsOf: moving, at: target)
        pinnedIDs = result; persist()
    }
    func shift(_ id: String, by delta: Int) {
        guard let index = pinnedIDs.firstIndex(of: id), pinnedIDs.indices.contains(index + delta) else { return }
        pinnedIDs.swapAt(index, index + delta); persist()
    }
    private func persist() { defaults.set(pinnedIDs, forKey: Self.storageKey) }
}
