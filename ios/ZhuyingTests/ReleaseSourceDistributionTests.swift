import XCTest
@testable import Zhuying

final class ReleaseSourceDistributionTests: XCTestCase {
    func testDistributionMetadataRetainsImportedHTTPRoutesWithoutBundledSources() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ZhuyingBundledSources") as? Bool, false)
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        XCTAssertGreaterThan(build, 16, "The new IPA must not reuse or downgrade the previously distributed build number")
        let transport = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        XCTAssertEqual(transport?["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    func testEnvironmentFlagsFollowTheBuildConfiguration() {
        let arguments = ["--demo", "--ui-testing", "--preserve-ui-test-state", "--production", "--live-source-acceptance"]
        let environment = AppEnvironment(arguments: arguments)
        #if DEBUG
        XCTAssertTrue(environment.isUITesting)
        XCTAssertTrue(environment.preservesTestState)
        XCTAssertTrue(AppEnvironment(arguments: ["--demo"]).isDemo)
        #else
        XCTAssertFalse(environment.isDemo)
        XCTAssertFalse(environment.isUITesting)
        XCTAssertFalse(environment.preservesTestState)
        XCTAssertFalse(environment.isLiveValidation)
        XCTAssertEqual(environment.defaultsDomain, "com.zhuying.production")
        XCTAssertFalse(AppEnvironment(arguments: ["--demo"]).isDemo)
        #endif
    }
    func testReleaseHasNoDefaultServiceOrSourceExamples() {
        #if DEBUG
        XCTAssertFalse(ShushanClient.defaultHost.isEmpty)
        #else
        XCTAssertEqual(ShushanClient.defaultHost, "")
        XCTAssertEqual(DemoSource(id: "user-draft", name: "", detail: "").url, "")
        XCTAssertEqual(FeatureCatalog.sampleJSON, "{}")
        XCTAssertEqual(SourceDistributionPolicy.unselectedSourceName, "未选择书源")
        #endif
    }
}
