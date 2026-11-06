import XCTest

/// Explicit scheme only. Uses the already authorized production Keychain login
/// but a dedicated library/defaults/cache; no credentials enter test arguments.
final class LiveSourceAcceptanceTests: XCTestCase {
    private struct Work: Decodable { let id: String; let title: String; let chapters: [Chapter] }
    private struct Chapter: Decodable { let order: Int; let title: String }
    @MainActor func testActualSourceSearchDetailsCatalogThreeChaptersAndRestartForTwoBooks() throws {
        continueAfterFailure = false
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"live-books",withExtension:"json")),works = try JSONDecoder().decode([Work].self,from:Data(contentsOf:url))
        XCTAssertEqual(works.count,2)
        let app = XCUIApplication(); app.launchArguments = ["--production","--live-source-acceptance"]
        for work in works {
            app.launch(); XCTAssertTrue(app.tabBars.buttons["搜索"].waitForExistence(timeout:15)); app.tabBars.buttons["搜索"].tap()
            let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout:8)); search.tap(); search.typeText(work.title + "\n")
            let result = app.buttons["online-result-" + work.id]; XCTAssertTrue(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'online-result-'")).firstMatch.waitForExistence(timeout:90))
            for _ in 0..<30 { if result.isHittable { break }; app.swipeUp() }; XCTAssertTrue(result.isHittable); result.tap()
            let read = app.buttons["detailRead"]; XCTAssertTrue(read.waitForExistence(timeout:15))
            let ready = expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:read); wait(for:[ready],timeout:90)
            let contents = app.buttons["detailContents"]; for _ in 0..<8 { if contents.isHittable { break }; app.swipeUp() }; contents.tap()
            let first = app.buttons["chapter-" + String(work.chapters[0].order)]; XCTAssertTrue(first.waitForExistence(timeout:8))
            for _ in 0..<10 { if first.isHittable { break }; app.swipeUp() }; first.tap()
            if app.buttons["dismissGestureGuide"].waitForExistence(timeout:3) { app.buttons["dismissGestureGuide"].tap() }
            for (index,chapter) in work.chapters.enumerated() {
                let text = app.textViews["continuousText"]
                let rendered = expectation(for:NSPredicate(format:"value CONTAINS %@",chapter.title),evaluatedWith:text); wait(for:[rendered],timeout:90)
                XCTAssertGreaterThan((text.value as? String)?.utf16.count ?? 0,300)
                if index < work.chapters.count - 1 { app.buttons["nextChapter"].tap() }
            }
            let before = app.textViews["continuousText"].value as? String
            let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Live-" + work.title + "-third-chapter"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["返回书架"].tap(); app.terminate(); app.launch(); XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout:15)); app.tabBars.buttons["我的"].tap()
            let resume = app.buttons["profileContinueReading"]; XCTAssertTrue(resume.waitForExistence(timeout:15)); resume.tap()
            let restored = expectation(for:NSPredicate(format:"value CONTAINS %@",work.chapters.last!.title),evaluatedWith:app.textViews["continuousText"]); wait(for:[restored],timeout:90)
            XCTAssertEqual(app.textViews["continuousText"].value as? String,before)
            app.buttons["返回书架"].tap(); app.terminate()
        }
    }
}
