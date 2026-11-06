import Foundation

/// Both modes share views; content providers and storage namespaces differ.
struct AppEnvironment: Equatable {
    enum Mode: String { case demo, production }
    let mode: Mode
    let isUITesting: Bool
    let preservesTestState: Bool
    let isLiveValidation: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        isUITesting = arguments.contains("--ui-testing")
        preservesTestState = arguments.contains("--preserve-ui-test-state")
        isLiveValidation = arguments.contains("--live-source-acceptance") && arguments.contains("--production") && !isUITesting
        if arguments.contains("--production") { mode = .production }
        else if arguments.contains("--demo") || isUITesting { mode = .demo }
        else { mode = .demo }
        #else
        isUITesting = false
        preservesTestState = false
        isLiveValidation = false
        mode = .production
        #endif
    }
    var isDemo: Bool { mode == .demo }
    var resetsTestState: Bool { isUITesting && !preservesTestState }
    var defaultsDomain: String? {
        if isLiveValidation { return "com.zhuying.live-acceptance" }
        if isUITesting { return isDemo ? "com.zhuying.ui-tests" : "com.zhuying.production.ui-tests" }
        return isDemo ? nil : "com.zhuying.production"
    }
    var importsComponent: String {
        if isLiveValidation { return "LiveAcceptance/ImportedBooks" }
        if isUITesting { return isDemo ? "UITestImports" : "ProductionUITestImports" }
        return isDemo ? "ImportedBooks" : "Production/ImportedBooks"
    }
    var fontsComponent: String {
        if isLiveValidation { return "LiveAcceptance/ReadingFonts" }
        if isUITesting { return isDemo ? "UITestReadingFonts" : "ProductionUITestReadingFonts" }
        return isDemo ? "ReadingFonts" : "Production/ReadingFonts"
    }
    var databaseComponent: String {
        if isLiveValidation { return "LiveAcceptance/Database" }
        if isUITesting { return isDemo ? "UITestDatabase" : "ProductionUITestDatabase" }
        return isDemo ? "DemoDatabase" : "Production/Database"
    }
    func defaults() -> UserDefaults {
        guard let defaultsDomain else { BrandCompatibility.migrateKeys(.standard); return .standard }
        let result = BrandCompatibility.defaults(domain: defaultsDomain, migrateLegacy: !isUITesting && !isLiveValidation)
        if resetsTestState { result.removePersistentDomain(forName: defaultsDomain) }
        return result
    }
}
