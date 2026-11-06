import XCTest
@testable import Yueshan

@MainActor private final class BubbleRenderProbe {
    var starts = 0
    var finished = 0
    var cancelledColors = Set<UInt32>()
    private var pending: [UInt32: CheckedContinuation<Data, Error>] = [:]
    func render(_ svg: String, theme: DemoTheme) async throws -> Data {
        starts += 1
        defer { finished += 1; if Task.isCancelled { cancelledColors.insert(theme.accent) } }
        return try await withCheckedThrowingContinuation { pending[theme.accent] = $0 }
    }
    func complete(_ accent: UInt32, _ result: Result<Data, Error>) { pending.removeValue(forKey: accent)?.resume(with: result) }
    func cancelAll() { let old = pending; pending = [:]; for continuation in old.values { continuation.resume(throwing: CancellationError()) } }
}

@MainActor final class BubbleRenderLifecycleTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
        XCTFail("Rendering did not reach the expected state")
    }
    private func setup(_ probe: BubbleRenderProbe) -> (FeatureDemoStore, LibraryStore, UserDefaults, String) {
        let domain = "bubble-lifecycle-\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        let library = LibraryStore(books: [], defaults: defaults)
        let demo = FeatureDemoStore(bubbleRenderer: { try await probe.render($0, theme: $1) })
        demo.connectReader(library)
        library.settings.preferences.colors = .init(background: 0xFFFFFF, ink: 0, accent: 0, name: "测试")
        library.settings.preferences.bubbleSVG = "<svg xmlns='http://www.w3.org/2000/svg'><rect width='72' height='44' fill='{{accent}}'/></svg>"
        return (demo, library, defaults, domain)
    }
    func testRepeatedRefreshCoalescesAndLateCancelledColorCannotOverwriteLatestPreview() async throws {
        let probe = BubbleRenderProbe(), (demo, library, defaults, domain) = setup(probe)
        defer { probe.cancelAll(); defaults.removePersistentDomain(forName: domain) }
        demo.refreshReaderBubbles(); demo.refreshReaderBubbles()
        try await wait { probe.starts == 1 }
        library.settings.preferences.colors?.accent = 0xFFFFFF
        demo.refreshReaderBubbles(); try await wait { probe.starts == 2 }
        let latest = Data("latest color".utf8)
        probe.complete(0xFFFFFF, .success(latest))
        try await wait { library.settings.preferences.bubbleImageData == latest }
        probe.complete(0, .success(Data("stale color".utf8)))
        try await wait { probe.finished == 2 }; await Task.yield()
        XCTAssertEqual(library.settings.preferences.bubbleImageData, latest)
        XCTAssertNil(demo.readerThemeMessage)
        demo.refreshReaderBubbles(); await Task.yield(); XCTAssertEqual(probe.starts, 2)
    }
    func testFailedRenderCanRetryWithoutChangingPaletteAndSuccessfulPreviewIsReused() async throws {
        let probe = BubbleRenderProbe(), (demo, library, defaults, domain) = setup(probe)
        defer { probe.cancelAll(); defaults.removePersistentDomain(forName: domain) }
        demo.refreshReaderBubbles(); try await wait { probe.starts == 1 }
        probe.complete(0, .failure(ContentFailure.unavailable))
        try await wait { demo.readerThemeMessage != nil }
        XCTAssertNil(library.settings.preferences.bubbleImageData)
        demo.refreshReaderBubbles(); try await wait { probe.starts == 2 }
        let repaired = Data("repaired preview".utf8); probe.complete(0, .success(repaired))
        try await wait { library.settings.preferences.bubbleImageData == repaired }
        XCTAssertNil(demo.readerThemeMessage)
        demo.refreshReaderBubbles(); await Task.yield(); XCTAssertEqual(probe.starts, 2)
    }
    func testPaletteRenameKeepsEquivalentInFlightPixels() async throws {
        let probe = BubbleRenderProbe(), (demo, library, defaults, domain) = setup(probe)
        defer { probe.cancelAll(); defaults.removePersistentDomain(forName: domain) }
        demo.refreshReaderBubbles(); try await wait { probe.starts == 1 }
        library.settings.preferences.colors?.name = "只修改名称"
        demo.refreshReaderBubbles(); await Task.yield(); XCTAssertEqual(probe.starts, 1)
        let image = Data("same pixels".utf8); probe.complete(0, .success(image))
        try await wait { library.settings.preferences.bubbleImageData == image }
    }
    func testOldLibraryCompletionCannotDiscardNewLibraryCancellationHandle() async throws {
        let probe = BubbleRenderProbe(), (demo, oldLibrary, defaults, domain) = setup(probe)
        defer { probe.cancelAll(); defaults.removePersistentDomain(forName: domain) }
        demo.refreshReaderBubbles(); try await wait { probe.starts == 1 }
        let library = LibraryStore(books: [], defaults: defaults)
        library.settings.preferences.colors?.accent = 0xFFFFFF
        demo.connectReader(library); try await wait { probe.starts == 2 }
        probe.complete(0, .success(Data("old library".utf8))); try await wait { probe.finished == 1 }
        library.settings.preferences.colors?.accent = 0xFF0000
        demo.refreshReaderBubbles(); try await wait { probe.starts == 3 }
        let latest = Data("red preview".utf8); probe.complete(0xFF0000, .success(latest))
        try await wait { library.settings.preferences.bubbleImageData == latest }
        probe.complete(0xFFFFFF, .success(Data("stale white".utf8))); try await wait { probe.finished == 3 }
        XCTAssertTrue(probe.cancelledColors.contains(0xFFFFFF))
        XCTAssertEqual(library.settings.preferences.bubbleImageData, latest)
        XCTAssertNil(oldLibrary.settings.preferences.bubbleImageData)
    }
    func testCancellingActiveWebKitRenderReleasesItsSlotAndContinuation() async throws {
        let baseline = ThemeBubbleRasterizer.activeRenders
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='72' height='44'><rect width='72' height='44' fill='{{accent}}'/><text x='2' y='20'>\(UUID().uuidString)</text></svg>"
        let theme = DemoTheme(id: "cancellation", name: "取消测试", mode: .light, background: 0xFFFFFF, ink: 0, accent: 0x567890, summary: "", source: "原创", version: "1")
        let task = Task { try await ThemeBubbleRasterizer.render(svg, theme: theme) }
        try await wait { ThemeBubbleRasterizer.activeRenders > baseline }
        task.cancel()
        do { _ = try await task.value; XCTFail("Active render should cancel") } catch is CancellationError {}
        XCTAssertEqual(ThemeBubbleRasterizer.activeRenders, baseline)
    }
}
