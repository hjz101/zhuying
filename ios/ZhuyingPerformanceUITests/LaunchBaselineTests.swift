import XCTest

final class LaunchBaselineTests: XCTestCase {
    @MainActor func testProductionEmptyLaunchTimeAndSharedShelfEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--production"]
        var samples: [Double] = []
        for _ in 0..<5 {
            app.terminate()
            let started = ProcessInfo.processInfo.systemUptime
            app.launch()
            let entry = app.buttons["shelfAddBook"]
            // launch() already waits for the app to idle. Probe immediately;
            // waitForExistence otherwise adds its first polling interval even
            // when the shelf is ready. The timer and hittable endpoint stay the same.
            if !entry.exists { XCTAssertTrue(entry.waitForExistence(timeout: 10)) }
            XCTAssertTrue(entry.isHittable, "Startup ends when the original shelf is usable")
            samples.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            XCTAssertTrue(app.staticTexts["这里还没有故事"].exists)
        }
        let record: [String: Any] = ["schemaVersion": 1, "profile": "simulator-debug-m4-ios26.5-v1", "id": "app.empty-launch.ms", "samples": samples, "maximum": samples.max()!, "limit": 3000, "withinTarget": samples.max()! <= 3000,
                                     "method": "XCTest process launch to hittable shelf; includes automation handshake; immediate existence probe with polling only when absent; not dyld-only startup"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "StepZero-Launch-Baseline"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
