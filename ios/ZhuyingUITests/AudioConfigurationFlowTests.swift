import XCTest

final class AudioConfigurationFlowTests: XCTestCase {
    @MainActor private func openConfig(_ app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        let tools = app.buttons["allTools"]
        for _ in 0..<8 { if tools.isHittable { break }; app.swipeUp() }; tools.tap()
        let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText("AI 服务配置")
        let entry = app.buttons["feature-aiConfig"]; XCTAssertTrue(entry.waitForExistence(timeout:5)); entry.tap()
        XCTAssertTrue(app.textFields["audioServiceName"].waitForExistence(timeout:5))
    }
    @MainActor func testCompatibleServiceMetadataRestartsWithoutConnectingOrPlaying() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing","--production"]; app.launch(); openConfig(app)
        let name = app.textFields["audioServiceName"]; name.tap(); name.typeText("原创配置服务")
        let url = app.textFields["audioServiceURL"]; url.tap(); url.typeText("https://service.invalid/v1")
        let model = app.textFields["audioTTSModel"]; model.tap(); model.typeText("test-speech")
        XCTAssertTrue(app.buttons["完成输入"].waitForExistence(timeout:3)); app.buttons["完成输入"].tap()
        app.swipeUp()
        let auth = app.switches["服务需要访问密钥"]
        for _ in 0..<5 { if auth.isHittable { break }; app.swipeUp() }; XCTAssertTrue(auth.isHittable); auth.tap()
        let save = app.buttons["audioServiceSave"]
        for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }; save.tap()
        let message = app.staticTexts["audioServiceMessage"]; XCTAssertTrue(message.waitForExistence(timeout:5)); XCTAssertTrue(message.label.contains("尚未测试连接"))
        XCTAssertFalse(app.otherElements["productionMiniPlayer"].exists)
        app.terminate(); app.launchArguments = ["--ui-testing","--production","--preserve-ui-test-state"]; app.launch(); openConfig(app)
        app.buttons["audioServiceSelection"].tap(); app.buttons["原创配置服务"].tap()
        XCTAssertEqual(app.textFields["audioServiceURL"].value as? String,"https://service.invalid/v1")
        XCTAssertEqual(app.textFields["audioTTSModel"].value as? String,"test-speech")
        XCTAssertFalse(app.secureTextFields["audioServiceKey"].exists)
        XCTAssertFalse(app.otherElements["productionMiniPlayer"].exists)
    }
    @MainActor func testNativeSystemSpeechStartsPausesResumesStopsAndRecordsListening() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing","--production","--narration-fixtures"]; app.launch()
        let read = app.buttons["阅读原创朗读测试"]
        XCTAssertTrue(read.waitForExistence(timeout:10))
        for _ in 0..<8 { if read.isHittable { break }; app.swipeUp() }; read.tap()
        XCTAssertTrue(app.buttons["readerNarration"].waitForExistence(timeout:5)); app.buttons["readerNarration"].tap()
        XCTAssertTrue(app.buttons["系统朗读"].waitForExistence(timeout:5)); app.buttons["系统朗读"].tap()
        let play = app.buttons["narrationPlay"]
        XCTAssertTrue(play.waitForExistence(timeout:5))
        for _ in 0..<8 { if play.isHittable { break }; app.swipeUp() }; play.tap()
        let playing = expectation(for:NSPredicate(format:"label CONTAINS '正在播放'"),evaluatedWith:app.staticTexts["narrationStatus"])
        wait(for:[playing],timeout:15)
        play.tap()
        let paused = expectation(for:NSPredicate(format:"label CONTAINS '已暂停'"),evaluatedWith:app.staticTexts["narrationStatus"])
        wait(for:[paused],timeout:5)
        play.tap()
        let resumed = expectation(for:NSPredicate(format:"label CONTAINS '正在播放'"),evaluatedWith:app.staticTexts["narrationStatus"])
        wait(for:[resumed],timeout:5)
        let stop = app.buttons["narrationStop"]; for _ in 0..<5 { if stop.isHittable { break }; app.swipeUp() }; stop.tap()
        XCTAssertEqual(app.staticTexts["narrationStatus"].label,"尚未播放")
        app.buttons["完成"].tap(); app.buttons["返回书架"].tap(); app.tabBars.buttons["足迹"].tap()
        let total = app.staticTexts["activityListeningTotal"]; XCTAssertTrue(total.waitForExistence(timeout:5)); XCTAssertFalse(total.label.contains("0 分钟"))
        app.terminate(); app.launchArguments = ["--ui-testing","--production","--preserve-ui-test-state"]; app.launch()
        XCTAssertFalse(app.otherElements["productionMiniPlayer"].exists)
        app.tabBars.buttons["足迹"].tap(); XCTAssertFalse(app.staticTexts["activityListeningTotal"].label.contains("0 分钟"))
    }
}
