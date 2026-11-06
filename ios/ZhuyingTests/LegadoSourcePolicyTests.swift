import XCTest
@testable import Zhuying

final class LegadoSourcePolicyTests: XCTestCase {
    func testOpaqueSourceDiscoversStaticLiteralsWithoutEvaluatingScriptsOrGuessingDynamicHosts() throws {
        let raw: [String: Any] = ["bookSourceUrl": "大灰狼融合VIP5.0", "jsLib": #"var host=['https://v5.fixture.test','https:\/\/v4.fixture.test']; /* 'https://comment.invalid' */ let dynamic=`https://${server}/api`; let cleartext='http://cleartext.invalid';"#]
        let policy = try LegadoSourcePolicy.declared(sourceID: "original-source", raw: raw)
        XCTAssertEqual(Set(policy.allowedOrigins.map(\.absoluteString)), ["https://v5.fixture.test/", "https://v4.fixture.test/", "http://cleartext.invalid/"])
        XCTAssertTrue(policy.allows(URL(string: "https://v5.fixture.test/search?q=竹影")!))
        XCTAssertFalse(policy.allows(URL(string: "https://unknown.fixture.test/")!))
        XCTAssertFalse(policy.allows(URL(string: "http://v5.fixture.test/")!))
    }
    func testAdditionalOriginsRequireExplicitConfigurationAndCredentialScopesRemainPerHostAndAccount() throws {
        let first = URL(string: "https://A.fixture.test:443/path")!, second = URL(string: "https://b.fixture.test/")!
        let policy = try LegadoSourcePolicy(sourceID: "source", declaredOrigins: [first])
        XCTAssertEqual(policy.allowedOrigins.first?.absoluteString, "https://a.fixture.test/")
        XCTAssertThrowsError(try policy.requireOrigin(for: second))
        let configured = try policy.addingOrigin(second.absoluteString)
        XCTAssertTrue(configured.allows(second))
        XCTAssertNotEqual(try configured.credentialScope(for: first, accountID: "one"), try configured.credentialScope(for: second, accountID: "one"))
        XCTAssertNotEqual(try configured.credentialScope(for: first, accountID: "one"), try configured.credentialScope(for: first, accountID: "two"))
        XCTAssertThrowsError(try policy.addingOrigin("https://user:password@b.fixture.test"))
        XCTAssertTrue(try policy.addingOrigin("http://b.fixture.test").allows(URL(string: "http://b.fixture.test/")!))
    }
}
