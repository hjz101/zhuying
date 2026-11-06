import XCTest
@testable import Zhuying

@MainActor final class ReadingShelfPromptTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        domain = "com.zhuying.shelf-prompt-tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testTwoMinutesOfVisibleReadingPromptsOnceAndPersistsDismissal() {
        let prompt = ReadingShelfPrompt(defaults: defaults, key: "prompt")
        for tick in 0..<120 {
            XCTAssertFalse(prompt.sample(bookID: "searched-book", active: true, eligible: true, uptime: Double(tick)))
        }
        XCTAssertTrue(prompt.sample(bookID: "searched-book", active: true, eligible: true, uptime: 120))
        XCTAssertFalse(prompt.sample(bookID: "searched-book", active: true, eligible: true, uptime: 121))
        let reopened = ReadingShelfPrompt(defaults: defaults, key: "prompt")
        for tick in 0...130 {
            XCTAssertFalse(reopened.sample(bookID: "searched-book", active: true, eligible: true, uptime: Double(tick)))
        }
    }

    func testBackgroundSheetsAndStallsDoNotCountAndBooksRemainIndependent() {
        let prompt = ReadingShelfPrompt(defaults: defaults, key: "prompt")
        for tick in 0...60 { XCTAssertFalse(prompt.sample(bookID: "first", active: true, eligible: true, uptime: Double(tick))) }
        XCTAssertFalse(prompt.sample(bookID: "first", active: false, eligible: true, uptime: 60))
        XCTAssertFalse(prompt.sample(bookID: "first", active: true, eligible: true, uptime: 900))
        // An unexpected timer gap is not evidence of visible reading.
        XCTAssertFalse(prompt.sample(bookID: "first", active: true, eligible: true, uptime: 1800))
        for tick in 1801..<1860 { XCTAssertFalse(prompt.sample(bookID: "first", active: true, eligible: true, uptime: Double(tick))) }
        XCTAssertTrue(prompt.sample(bookID: "first", active: true, eligible: true, uptime: 1860))
        for tick in 1861..<1981 { XCTAssertFalse(prompt.sample(bookID: "second", active: true, eligible: true, uptime: Double(tick))) }
        XCTAssertTrue(prompt.sample(bookID: "second", active: true, eligible: true, uptime: 1981))
    }

    func testShelvedBookNeverPromptsAndDoesNotConsumeFutureInvitation() {
        let prompt = ReadingShelfPrompt(defaults: defaults, key: "prompt")
        for tick in 0...150 { XCTAssertFalse(prompt.sample(bookID: "book", active: true, eligible: false, uptime: Double(tick))) }
        XCTAssertNil(defaults.stringArray(forKey: "prompt"))
        for tick in 151...270 { XCTAssertFalse(prompt.sample(bookID: "book", active: true, eligible: true, uptime: Double(tick))) }
        XCTAssertTrue(prompt.sample(bookID: "book", active: true, eligible: true, uptime: 271))
    }
}
