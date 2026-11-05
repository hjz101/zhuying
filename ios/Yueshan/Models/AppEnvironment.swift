import Foundation

/// Both modes share views; content providers and storage namespaces differ.
struct AppEnvironment: Equatable {
    enum Mode: String { case demo, production }
    let mode: Mode
    let isUITesting: Bool
    let preservesTestState: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        isUITesting = arguments.contains("--ui-testing")
        preservesTestState = arguments.contains("--preserve-ui-test-state")
        if arguments.contains("--production") { mode = .production }
        else if arguments.contains("--demo") || isUITesting { mode = .demo }
        else {
            #if DEBUG
            mode = .demo
            #else
            mode = .production
            #endif
        }
    }
    var isDemo: Bool { mode == .demo }
    var resetsTestState: Bool { isUITesting && !preservesTestState }
    var defaultsDomain: String? {
        if isUITesting { return isDemo ? "com.yueshan.ui-tests" : "com.yueshan.production.ui-tests" }
        return isDemo ? nil : "com.yueshan.production"
    }
    var importsComponent: String {
        if isUITesting { return isDemo ? "UITestImports" : "ProductionUITestImports" }
        return isDemo ? "ImportedBooks" : "Production/ImportedBooks"
    }
    var fontsComponent: String {
        if isUITesting { return isDemo ? "UITestReadingFonts" : "ProductionUITestReadingFonts" }
        return isDemo ? "ReadingFonts" : "Production/ReadingFonts"
    }
    var databaseComponent: String {
        if isUITesting { return isDemo ? "UITestDatabase" : "ProductionUITestDatabase" }
        return isDemo ? "DemoDatabase" : "Production/Database"
    }
    func defaults() -> UserDefaults {
        guard let defaultsDomain else { return .standard }
        let result = UserDefaults(suiteName: defaultsDomain)!
        if resetsTestState { result.removePersistentDomain(forName: defaultsDomain) }
        return result
    }
}
