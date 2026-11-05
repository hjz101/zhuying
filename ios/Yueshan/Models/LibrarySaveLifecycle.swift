import UIKit

@MainActor
private final class LibrarySaveLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "保存阅读记录") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@MainActor extension LibraryStore {
    func saveBeforeSuspending() async {
        let lease = LibrarySaveLease()
        defer { lease.end() }
        await flushPendingWrites()
    }
}
