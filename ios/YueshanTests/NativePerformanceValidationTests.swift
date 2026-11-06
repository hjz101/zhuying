#if DEBUG
import XCTest
@testable import Yueshan
@MainActor final class NativePerformanceValidationTests: XCTestCase {
    func testStandaloneReportMeasuresFullUnicodeWorkloadAndStatesDifferentStartupBoundary() {
        let report = NativePerformanceValidation.measure(readyMS: 123)
        XCTAssertEqual(report.appInitializationToReadyMS, 123)
        XCTAssertGreaterThanOrEqual(report.utf16Units, 100_000)
        XCTAssertGreaterThan(report.pages, 1); XCTAssertTrue(report.contentPreserved)
        XCTAssertGreaterThan(report.paginateMS, 0); XCTAssertGreaterThan(report.reflowMS, 0)
        XCTAssertGreaterThan(report.peakRSSMiB, 0)
        XCTAssertTrue(report.method.contains("excludes dyld")); XCTAssertTrue(report.method.contains("does not replace"))
    }
}
#endif
